%% -------- Inker ---------
%% 
%% The Inker is responsible for managing access and updates to the Journal. 
%%
%% The Inker maintains a manifest of what files make up the Journal, and which
%% file is the current append-only nursery log to accept new PUTs into the
%% Journal.  The Inker also marshals GET requests to the appropriate database
%% file within the Journal (routed by sequence number).  The Inker is also
%% responsible for scheduling compaction work to be carried out by the Inker's
%% clerk.
%%
%% -------- Journal ---------
%%
%% The Journal is a series of files originally named as <SQN>_nursery.cdb
%% where the sequence number is the first object sequence number (key) within
%% the given database file.  The files will be named *.cdb at the point they
%% have been made immutable (through a rename operation).  Prior to this, they
%% will originally start out as a *.pnd file.
%%
%% At some stage in the future compacted versions of old journal cdb files may
%% be produced.  These files will be named <SQN>-<CompactionID>.cdb, and once
%% the manifest is updated the original <SQN>_nursery.cdb (or
%% <SQN>_<previous CompactionID>.cdb) files they replace will be erased.
%%
%% The current Journal is made up of a set of files referenced in the manifest,
%% combined with a set of files of the form <SQN>_nursery.[cdb|pnd] with
%% a higher Sequence Number compared to the files in the manifest.
%% 
%% The Journal is ordered by sequence number from front to back both within
%% and across files.  
%%
%% On startup the Inker should open the manifest with the highest sequence
%% number, and this will contain the list of filenames that make up the
%% non-recent part of the Journal.  The Manifest is completed by opening these
%% files plus any other files with a higher sequence number.  The file with
%% the highest sequence number is assumed to to be the active writer.  Any file
%% with a lower sequence number and a *.pnd extension should be re-rolled into
%% a *.cdb file. 
%%
%% -------- Objects ---------
%%
%% From the perspective of the Inker, objects to store are made up of:
%% - A Primary Key (as an Erlang term)
%% - A sequence number (assigned by the Inker)
%% - An object (an Erlang term)
%% - A set of Key Deltas associated with the change
%%
%% -------- Manifest ---------
%%
%% The Journal has a manifest which is the current record of which cdb files
%% are currently active in the Journal (i.e. following compaction). The
%% manifest holds this information through two lists - a list of files which
%% are definitely in the current manifest, and a list of files which have been
%% removed, but may still be present on disk.  The use of two lists is to 
%% avoid any circumsatnces where a compaction event has led to the deletion of 
%% a Journal file with a higher sequence number than any in the remaining
%% manifest.
%%
%% A new manifest file is saved for every compaction event.  The manifest files
%% are saved using the filename <ManifestSQN>.man once saved.  The ManifestSQN
%% is incremented once for every compaction event.
%%
%% -------- Compaction ---------
%%
%% Compaction is a process whereby an Inker's clerk will:
%% - Request a snapshot of the Ledger, as well as the lowest sequence number
%% that is currently registerd by another snapshot owner
%% - Picks a Journal database file at random (not including the current
%% nursery log)
%% - Performs a random walk on keys and sequence numbers in the chosen CDB
%% file to extract a subset of 100 key and sequence number combinations from
%% the database
%% - Looks up the current sequence number for those keys in the Ledger
%% - If more than <n>% (default n=20) of the keys are now at a higher sequence
%% number, then the database file is a candidate for compaction.  In this case
%% each of the next 8 files in sequence should be checked until all those 8
%% files have been checked or one of the files has been found to be below the
%% threshold.
%% - If a set of below-the-threshold files is found, the files are re-written
%% without any superceded values
%%- The clerk should then request that the Inker commit the manifest change
%%
%% -------- Inker's Clerk ---------
%%
%%
%%
%%

-module(leveled_inker).

-behaviour(gen_server).

-include("../include/leveled.hrl").

-export([init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3,
        ink_start/1,
        ink_put/4,
        ink_get/3,
        ink_fetch/3,
        ink_loadpcl/4,
        ink_registersnapshot/2,
        ink_compactjournal/3,
        ink_compactioncomplete/1,
        ink_getmanifest/1,
        ink_updatemanifest/3,
        ink_print_manifest/1,
        ink_close/1,
        ink_forceclose/1,
        build_dummy_journal/0,
        simple_manifest_reader/2,
        clean_testdir/1,
        filepath/2,
        filepath/3]).

-include_lib("eunit/include/eunit.hrl").

-define(MANIFEST_FP, "journal_manifest").
-define(FILES_FP, "journal_files").
-define(COMPACT_FP, "post_compact").
-define(JOURNAL_FILEX, "cdb").
-define(MANIFEST_FILEX, "man").
-define(PENDING_FILEX, "pnd").
-define(LOADING_PAUSE, 5000).
-define(LOADING_BATCH, 1000).

-record(state, {manifest = [] :: list(),
				manifest_sqn = 0 :: integer(),
                journal_sqn = 0 :: integer(),
                active_journaldb :: pid(),
                active_journaldb_sqn :: integer(),
                pending_removals = [] :: list(),
                registered_snapshots = [] :: list(),
                root_path :: string(),
                cdb_options :: #cdb_options{},
                clerk :: pid(),
                compaction_pending = false :: boolean(),
                is_snapshot = false :: boolean(),
                source_inker :: pid()}).


%%%============================================================================
%%% API
%%%============================================================================
 
ink_start(InkerOpts) ->
    gen_server:start(?MODULE, [InkerOpts], []).

ink_put(Pid, PrimaryKey, Object, KeyChanges) ->
    gen_server:call(Pid, {put, PrimaryKey, Object, KeyChanges}, infinity).

ink_get(Pid, PrimaryKey, SQN) ->
    gen_server:call(Pid, {get, PrimaryKey, SQN}, infinity).

ink_fetch(Pid, PrimaryKey, SQN) ->
    gen_server:call(Pid, {fetch, PrimaryKey, SQN}, infinity).

ink_registersnapshot(Pid, Requestor) ->
    gen_server:call(Pid, {register_snapshot, Requestor}, infinity).

ink_releasesnapshot(Pid, Snapshot) ->
    gen_server:call(Pid, {release_snapshot, Snapshot}, infinity).

ink_close(Pid) ->
    gen_server:call(Pid, {close, false}, infinity).

ink_forceclose(Pid) ->
    gen_server:call(Pid, {close, true}, infinity).

ink_loadpcl(Pid, MinSQN, FilterFun, Penciller) ->
    gen_server:call(Pid, {load_pcl, MinSQN, FilterFun, Penciller}, infinity).

ink_compactjournal(Pid, Bookie, Timeout) ->
    CheckerInitiateFun = fun initiate_penciller_snapshot/1,
    CheckerFilterFun = fun leveled_penciller:pcl_checksequencenumber/3,
    gen_server:call(Pid,
                        {compact,
                            Bookie,
                            CheckerInitiateFun,
                            CheckerFilterFun,
                            Timeout},
                        infinity).

%% Allows the Checker to be overriden in test, use something other than a
%% penciller
ink_compactjournal(Pid, Checker, InitiateFun, FilterFun, Timeout) ->
    gen_server:call(Pid,
                        {compact,
                            Checker,
                            InitiateFun,
                            FilterFun,
                            Timeout},
                        infinity).

ink_compactioncomplete(Pid) ->
    gen_server:call(Pid, compaction_complete, infinity).

ink_getmanifest(Pid) ->
    gen_server:call(Pid, get_manifest, infinity).

ink_updatemanifest(Pid, ManifestSnippet, DeletedFiles) ->
    gen_server:call(Pid,
                        {update_manifest,
                            ManifestSnippet,
                            DeletedFiles},
                        infinity).

ink_print_manifest(Pid) ->
    gen_server:call(Pid, print_manifest, infinity).

%%%============================================================================
%%% gen_server callbacks
%%%============================================================================

init([InkerOpts]) ->
    case {InkerOpts#inker_options.root_path,
            InkerOpts#inker_options.start_snapshot} of
        {undefined, true} ->
            SrcInker = InkerOpts#inker_options.source_inker,
            {Manifest,
                ActiveJournalDB,
                ActiveJournalSQN} = ink_registersnapshot(SrcInker, self()),
            {ok, #state{manifest=Manifest,
                            active_journaldb=ActiveJournalDB,
                            active_journaldb_sqn=ActiveJournalSQN,
                            source_inker=SrcInker,
                            is_snapshot=true}};
            %% Need to do something about timeout
        {_RootPath, false} ->
            start_from_file(InkerOpts)
    end.


handle_call({put, Key, Object, KeyChanges}, From, State) ->
    case put_object(Key, Object, KeyChanges, State) of
        {ok, UpdState, ObjSize} ->
            {reply, {ok, UpdState#state.journal_sqn, ObjSize}, UpdState};
        {rolling, UpdState, ObjSize} ->
            gen_server:reply(From, {ok, UpdState#state.journal_sqn, ObjSize}),
            {NewManifest,
                NewManifestSQN} = roll_active_file(State#state.active_journaldb,
                                                    State#state.manifest,
                                                    State#state.manifest_sqn,
                                                    State#state.root_path),
            {noreply, UpdState#state{manifest=NewManifest,
                                        manifest_sqn=NewManifestSQN}};
        {blocked, UpdState} ->
            {reply, blocked, UpdState}
    end;
handle_call({fetch, Key, SQN}, _From, State) ->
    case get_object(Key,
                        SQN,
                        State#state.manifest,
                        State#state.active_journaldb,
                        State#state.active_journaldb_sqn) of
        {{SQN, Key}, {Value, _IndexSpecs}} ->
            {reply, {ok, Value}, State};
        Other ->
            io:format("Unexpected failure to fetch value for" ++
                        "Key=~w SQN=~w with reason ~w", [Key, SQN, Other]),
            {reply, not_present, State}
    end;
handle_call({get, Key, SQN}, _From, State) ->
    {reply, get_object(Key,
                        SQN,
                        State#state.manifest,
                        State#state.active_journaldb,
                        State#state.active_journaldb_sqn), State};
handle_call({load_pcl, StartSQN, FilterFun, Penciller}, _From, State) ->
    Manifest = lists:reverse(State#state.manifest)
                ++ [{State#state.active_journaldb_sqn,
                        dummy,
                        State#state.active_journaldb}],
    Reply = load_from_sequence(StartSQN, FilterFun, Penciller, Manifest),
    {reply, Reply, State};
handle_call({register_snapshot, Requestor}, _From , State) ->
    Rs = [{Requestor,
            State#state.manifest_sqn}|State#state.registered_snapshots],
    io:format("Inker snapshot ~w registered at SQN ~w~n",
                    [Requestor, State#state.manifest_sqn]),
    {reply, {State#state.manifest,
                State#state.active_journaldb,
                State#state.active_journaldb_sqn},
                State#state{registered_snapshots=Rs}};
handle_call({release_snapshot, Snapshot}, _From , State) ->
    Rs = lists:keydelete(Snapshot, 1, State#state.registered_snapshots),
    io:format("Snapshot ~w released~n", [Snapshot]),
    io:format("Remaining snapshots are ~w~n", [Rs]),
    {reply, ok, State#state{registered_snapshots=Rs}};
handle_call(get_manifest, _From, State) ->
    {reply, State#state.manifest, State};
handle_call({update_manifest,
                ManifestSnippet,
                DeletedFiles}, _From, State) ->
    Man0 = lists:foldl(fun(ManEntry, AccMan) ->
                            Check = lists:member(ManEntry, DeletedFiles),
                            if
                                Check == false ->
                                    AccMan ++ [ManEntry];
                                true ->
                                    AccMan
                            end
                            end,
                        [],
                        State#state.manifest),                    
    Man1 = lists:foldl(fun(ManEntry, AccMan) ->
                            add_to_manifest(AccMan, ManEntry) end,
                        Man0,
                        ManifestSnippet),
    NewManifestSQN = State#state.manifest_sqn + 1,
    ok = simple_manifest_writer(Man1, NewManifestSQN, State#state.root_path),
    PendingRemovals = [{NewManifestSQN, DeletedFiles}],
    {reply, ok, State#state{manifest=Man1,
                                manifest_sqn=NewManifestSQN,
                                pending_removals=PendingRemovals}};
handle_call(print_manifest, _From, State) ->
    manifest_printer(State#state.manifest),
    {reply, ok, State};
handle_call({compact,
                Checker,
                InitiateFun,
                FilterFun,
                Timeout},
                    _From, State) ->
    leveled_iclerk:clerk_compact(State#state.clerk,
                                    Checker,
                                    InitiateFun,
                                    FilterFun,
                                    self(),
                                    Timeout),
    {reply, ok, State#state{compaction_pending=true}};
handle_call(compaction_complete, _From, State) ->
    {reply, ok, State#state{compaction_pending=false}};
handle_call({close, Force}, _From, State) ->
    case {State#state.compaction_pending, Force} of
        {true, false} ->
            {reply, pause, State};
        _ ->
            {stop, normal, ok, State}
    end;
handle_call(Msg, _From, State) ->
    io:format("Unexpected message ~w~n", [Msg]),
    {reply, error, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, State) ->
    case State#state.is_snapshot of
        true ->
            ok = ink_releasesnapshot(State#state.source_inker, self());
        false ->    
            io:format("Inker closing journal for reason ~w~n", [Reason]),
            io:format("Close triggered with journal_sqn=~w and manifest_sqn=~w~n",
                            [State#state.journal_sqn, State#state.manifest_sqn]),
            io:format("Manifest when closing is: ~n"),
            leveled_iclerk:clerk_stop(State#state.clerk),
            lists:foreach(fun({Snap, _SQN}) -> ok = ink_close(Snap) end,
                            State#state.registered_snapshots),
            manifest_printer(State#state.manifest),
            close_allmanifest(State#state.manifest, State#state.active_journaldb),
            close_allremovals(State#state.pending_removals)
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%============================================================================
%%% Internal functions
%%%============================================================================

start_from_file(InkerOpts) ->
    RootPath = InkerOpts#inker_options.root_path,
    CDBopts = InkerOpts#inker_options.cdb_options,
    JournalFP = filepath(RootPath, journal_dir),
    {ok, JournalFilenames} = case filelib:is_dir(JournalFP) of
        true ->
            file:list_dir(JournalFP);
        false ->
            filelib:ensure_dir(JournalFP),
            {ok, []}
    end,
    ManifestFP = filepath(RootPath, manifest_dir),
    {ok, ManifestFilenames} = case filelib:is_dir(ManifestFP) of
        true ->
            file:list_dir(ManifestFP);
        false ->
            filelib:ensure_dir(ManifestFP),
            {ok, []}
    end,
    
    CompactFP = filepath(RootPath, journal_compact_dir),
    filelib:ensure_dir(CompactFP),
    IClerkCDBOpts = CDBopts#cdb_options{file_path = CompactFP},
    IClerkOpts = #iclerk_options{inker = self(),
                                    cdb_options=IClerkCDBOpts},
    {ok, Clerk} = leveled_iclerk:clerk_new(IClerkOpts),
    
    {Manifest,
        {ActiveJournal, LowActiveSQN},
        JournalSQN,
        ManifestSQN} = build_manifest(ManifestFilenames,
                                        JournalFilenames,
                                        fun simple_manifest_reader/2,
                                        RootPath,
                                        CDBopts),
    {ok, #state{manifest = lists:reverse(lists:keysort(1, Manifest)),
                    manifest_sqn = ManifestSQN,
                    journal_sqn = JournalSQN,
                    active_journaldb = ActiveJournal,
                    active_journaldb_sqn = LowActiveSQN,
                    root_path = RootPath,
                    cdb_options = CDBopts,
                    clerk = Clerk}}.


put_object(PrimaryKey, Object, KeyChanges, State) ->
    NewSQN = State#state.journal_sqn + 1,
    %% TODO: The term goes through a double binary_to_term conversion
    %% as the CDB will also do the same conversion
    %% Perhaps have CDB started up in apure binary mode, when it doesn't
    %5 receive terms?
    Bin1 = term_to_binary({Object, KeyChanges}, [compressed]),
    ObjSize = byte_size(Bin1),
    case leveled_cdb:cdb_put(State#state.active_journaldb,
                                {NewSQN, PrimaryKey},
                                Bin1) of
        ok ->
            {ok, State#state{journal_sqn=NewSQN}, ObjSize};
        roll ->
            FileName = filepath(State#state.root_path, NewSQN, new_journal),
            CDBopts = State#state.cdb_options,
            {ok, NewJournalP} = leveled_cdb:cdb_open_writer(FileName, CDBopts),
            case leveled_cdb:cdb_put(NewJournalP,
                                        {NewSQN, PrimaryKey},
                                        Bin1) of
                ok ->
                    {rolling,
                        State#state{journal_sqn=NewSQN,
                                        active_journaldb=NewJournalP,
                                        active_journaldb_sqn=NewSQN},
                        ObjSize};
                roll ->
                    {blocked, State#state{journal_sqn=NewSQN,
                                            active_journaldb=NewJournalP,
                                            active_journaldb_sqn=NewSQN}}
            end
    end.

roll_active_file(ActiveJournal, Manifest, ManifestSQN, RootPath) ->
    SW = os:timestamp(),
    io:format("Rolling old journal ~w~n", [ActiveJournal]),
    {ok, NewFilename} = leveled_cdb:cdb_roll(ActiveJournal),
    JournalRegex2 = "nursery_(?<SQN>[0-9]+)\\." ++ ?JOURNAL_FILEX,
    [JournalSQN] = sequencenumbers_fromfilenames([NewFilename],
                                                    JournalRegex2,
                                                    'SQN'),
    NewManifest = add_to_manifest(Manifest,
                                    {JournalSQN, NewFilename, ActiveJournal}),
    NewManifestSQN = ManifestSQN + 1,
    ok = simple_manifest_writer(NewManifest, NewManifestSQN, RootPath),
    io:format("Rolling old journal completed in ~w microseconds~n",
                [timer:now_diff(os:timestamp(),SW)]),
    {NewManifest, NewManifestSQN}.

get_object(PrimaryKey, SQN, Manifest, ActiveJournal, ActiveJournalSQN) ->
    Obj = if
        SQN < ActiveJournalSQN ->
            JournalP = find_in_manifest(SQN, Manifest),
            if 
                JournalP == error ->
                    io:format("Unable to find SQN~w in Manifest~w~n",
                                [SQN, Manifest]),
                    error;
                true ->
                    leveled_cdb:cdb_get(JournalP, {SQN, PrimaryKey})
            end;
        true ->
            leveled_cdb:cdb_get(ActiveJournal, {SQN, PrimaryKey})
    end,
    case Obj of
        {{SQN, PK}, Bin} ->
            {{SQN, PK}, binary_to_term(Bin)};
        _ ->
            Obj
    end.


build_manifest(ManifestFilenames,
                JournalFilenames,
                ManifestRdrFun,
                RootPath) ->
    build_manifest(ManifestFilenames,
                    JournalFilenames,
                    ManifestRdrFun,
                    RootPath,
                    #cdb_options{}).

build_manifest(ManifestFilenames,
                JournalFilenames,
                ManifestRdrFun,
                RootPath,
                CDBopts) ->
    %% Find the manifest with a highest Manifest sequence number
    %% Open it and read it to get the current Confirmed Manifest
    ManifestRegex = "(?<MSQN>[0-9]+)\\." ++ ?MANIFEST_FILEX,
    ValidManSQNs = sequencenumbers_fromfilenames(ManifestFilenames,
                                                    ManifestRegex,
                                                    'MSQN'),
    {JournalSQN1,
        ConfirmedManifest,
        Removed,
        ManifestSQN} = case length(ValidManSQNs) of
                            0 ->
                                {0, [], [], 0};
                            _ ->
                                PersistedManSQN = lists:max(ValidManSQNs),
                                M1 = ManifestRdrFun(PersistedManSQN, RootPath),
                                J1 = lists:foldl(fun({JSQN, _FN}, Acc) ->
                                                        max(JSQN, Acc) end,
                                                    0,
                                                    M1),
                                {J1, M1, [], PersistedManSQN}
                        end,
    
    %% Find any more recent immutable files that have a higher sequence number
    %% - the immutable files have already been rolled, and so have a completed
    %% hashtree lookup
    JournalRegex1 = "nursery_(?<SQN>[0-9]+)\\." ++ ?JOURNAL_FILEX,
    UnremovedJournalFiles = lists:foldl(fun(FN, Acc) ->
                                            case lists:member(FN, Removed) of
                                                true ->
                                                    Acc;
                                                false ->
                                                    Acc ++ [FN]
                                            end end,
                                        [],
                                        JournalFilenames),
    OtherSQNs_imm = sequencenumbers_fromfilenames(UnremovedJournalFiles,
                                                    JournalRegex1,
                                                    'SQN'),
    ExtendManifestFun = fun(X, Acc) ->
                            if
                                X > JournalSQN1
                                    ->
                                        FN = filepath(RootPath, journal_dir) 
                                                ++ "nursery_" ++
                                                integer_to_list(X)
                                                ++ "." ++
                                                ?JOURNAL_FILEX,
                                        add_to_manifest(Acc, {X, FN});
                                true
                                    -> Acc
                            end end,
    Manifest1 = lists:foldl(ExtendManifestFun,
                                ConfirmedManifest,
                                lists:sort(OtherSQNs_imm)),
    
    %% Enrich the manifest so it contains the Pid of any of the immutable 
    %% entries
    io:format("Manifest on startup is: ~n"),
    manifest_printer(Manifest1),
    Manifest2 = lists:map(fun({LowSQN, FN}) ->
                                {ok, Pid} = leveled_cdb:cdb_open_reader(FN),
                                {LowSQN, FN, Pid} end,
                            Manifest1),
    
    %% Find any more recent mutable files that have a higher sequence number
    %% Roll any mutable files which do not have the highest sequence number
    %% to create the hashtree and complete the header entries
    JournalRegex2 = "nursery_(?<SQN>[0-9]+)\\." ++ ?PENDING_FILEX,
    OtherSQNs_pnd = sequencenumbers_fromfilenames(JournalFilenames,
                                                    JournalRegex2,
                                                    'SQN'),
    
    case length(OtherSQNs_pnd) of
        0 ->
            %% Need to create a new active writer, but also find the highest
            %% SQN from within the confirmed manifest
            TopSQNInManifest =
                case length(Manifest2) of
                    0 ->
                        %% Manifest is empty and no active writers
                        %% can be found so database is empty
                        0;
                    _ ->
                        TM = lists:last(lists:keysort(1,Manifest2)),
                        {_SQN, _FN, TMPid} = TM,
                        {HighSQN, _HighKey} = leveled_cdb:cdb_lastkey(TMPid),
                        HighSQN
                end,
            LowActiveSQN = TopSQNInManifest + 1,
            ActiveFN = filepath(RootPath, LowActiveSQN, new_journal),
            {ok, ActiveJournal} = leveled_cdb:cdb_open_writer(ActiveFN,
                                                                CDBopts),
            {Manifest2,
                {ActiveJournal, LowActiveSQN},
                TopSQNInManifest,
                ManifestSQN};
        _ ->
            {ActiveJournalSQN,
                Manifest3} = roll_pending_journals(lists:sort(OtherSQNs_pnd),
                                                    Manifest2,
                                                    RootPath),
            %% Need to work out highest sequence number in tail file to feed 
            %% into opening of pending journal
            ActiveFN = filepath(RootPath, ActiveJournalSQN, new_journal),
            {ok, ActiveJournal} = leveled_cdb:cdb_open_writer(ActiveFN,
                                                                CDBopts),
            {HighestSQN, _HighestKey} = leveled_cdb:cdb_lastkey(ActiveJournal),
            {Manifest3,
                {ActiveJournal, ActiveJournalSQN},
                HighestSQN,
                ManifestSQN}
    end.

close_allmanifest([], ActiveJournal) ->
    leveled_cdb:cdb_close(ActiveJournal);
close_allmanifest([H|ManifestT], ActiveJournal) ->
    {_, _, Pid} = H,
    ok = leveled_cdb:cdb_close(Pid),
    close_allmanifest(ManifestT, ActiveJournal).

close_allremovals([]) ->
    ok;
close_allremovals([{ManifestSQN, Removals}|Tail]) ->
    io:format("Closing removals at ManifestSQN=~w~n", [ManifestSQN]),
    lists:foreach(fun({LowSQN, FN, Handle}) ->
                        io:format("Closing removed file with LowSQN=~w" ++
                                        " and filename ~s~n",
                                    [LowSQN, FN]),
                        if
                            is_pid(Handle) == true ->
                                ok = leveled_cdb:cdb_close(Handle);
                            true ->
                                io:format("Non pid in removal ~w - test~n",
                                            [Handle])
                        end
                        end,
                    Removals),
    close_allremovals(Tail).


roll_pending_journals([TopJournalSQN], Manifest, _RootPath)
                        when is_integer(TopJournalSQN) ->
    {TopJournalSQN, Manifest};
roll_pending_journals([JournalSQN|T], Manifest, RootPath) ->
    Filename = filepath(RootPath, JournalSQN, new_journal),
    {ok, PidW} = leveled_cdb:cdb_open_writer(Filename),
    {ok, NewFilename} = leveled_cdb:cdb_complete(PidW),
    {ok, PidR} = leveled_cdb:cdb_open_reader(NewFilename),
    roll_pending_journals(T,
                            add_to_manifest(Manifest,
                                            {JournalSQN, NewFilename, PidR}),
                            RootPath).


%% Scan between sequence numbers applying FilterFun to each entry where
%% FilterFun{K, V, Acc} -> Penciller Key List
%% Load the output for the CDB file into the Penciller.

load_from_sequence(_MinSQN, _FilterFun, _Penciller, []) ->
    ok;
load_from_sequence(MinSQN, FilterFun, Penciller, [{LowSQN, FN, Pid}|Rest])
                                        when LowSQN >= MinSQN ->
    load_between_sequence(MinSQN,
                            MinSQN + ?LOADING_BATCH,
                            FilterFun,
                            Penciller,
                            Pid,
                            undefined,
                            FN,
                            Rest);
load_from_sequence(MinSQN, FilterFun, Penciller, [{_LowSQN, FN, Pid}|Rest]) ->
    case Rest of
        [] ->
            load_between_sequence(MinSQN,
                                    MinSQN + ?LOADING_BATCH,
                                    FilterFun,
                                    Penciller,
                                    Pid,
                                    undefined,
                                    FN,
                                    Rest);
        [{NextSQN, _FN, Pid}|_Rest] when NextSQN > MinSQN ->
            load_between_sequence(MinSQN,
                                    MinSQN + ?LOADING_BATCH,
                                    FilterFun,
                                    Penciller,
                                    Pid,
                                    undefined,
                                    FN,
                                    Rest);
        _ ->
            load_from_sequence(MinSQN, FilterFun, Penciller, Rest)
    end.



load_between_sequence(MinSQN, MaxSQN, FilterFun, Penciller,
                                CDBpid, StartPos, FN, Rest) ->
    io:format("Loading from filename ~s from SQN ~w~n", [FN, MinSQN]),
    InitAcc = {MinSQN, MaxSQN, []},
    Res = case leveled_cdb:cdb_scan(CDBpid, FilterFun, InitAcc, StartPos) of
                {eof, {AccMinSQN, _AccMaxSQN, AccKL}} ->
                    ok = push_to_penciller(Penciller, AccKL),
                    {ok, AccMinSQN};
                {LastPosition, {_AccMinSQN, _AccMaxSQN, AccKL}} ->
                    ok = push_to_penciller(Penciller, AccKL),
                    NextSQN = MaxSQN + 1,
                    load_between_sequence(NextSQN,
                                            NextSQN + ?LOADING_BATCH,
                                            FilterFun,
                                            Penciller,
                                            CDBpid,
                                            LastPosition,
                                            FN,
                                            Rest)
            end,
    case Res of
        {ok, LMSQN} ->
            load_from_sequence(LMSQN, FilterFun, Penciller, Rest);
        ok ->
            ok
    end.

push_to_penciller(Penciller, KeyList) ->
    R = leveled_penciller:pcl_pushmem(Penciller, KeyList),
    if
        R == pause ->
            timer:sleep(?LOADING_PAUSE);
        true ->
            ok
    end.
            

sequencenumbers_fromfilenames(Filenames, Regex, IntName) ->
    lists:foldl(fun(FN, Acc) ->
                            case re:run(FN,
                                        Regex,
                                        [{capture, [IntName], list}]) of
                                nomatch ->
                                    Acc;
                                {match, [Int]} when is_list(Int) ->
                                    Acc ++ [list_to_integer(Int)];       
                                _ ->
                                    Acc
                            end end,
                            [],
                            Filenames).

add_to_manifest(Manifest, Entry) ->
    lists:reverse(lists:sort([Entry|Manifest])).

find_in_manifest(_SQN, []) ->
    error;
find_in_manifest(SQN, [{LowSQN, _FN, Pid}|_Tail]) when SQN >= LowSQN ->
    Pid;
find_in_manifest(SQN, [_Head|Tail]) ->
    find_in_manifest(SQN, Tail).

filepath(RootPath, journal_dir) ->
    RootPath ++ "/" ++ ?FILES_FP ++ "/";
filepath(RootPath, manifest_dir) ->
    RootPath ++ "/" ++ ?MANIFEST_FP ++ "/";
filepath(RootPath, journal_compact_dir) ->
    filepath(RootPath, journal_dir) ++ "/" ++ ?COMPACT_FP ++ "/".

filepath(RootPath, NewSQN, new_journal) ->
    filename:join(filepath(RootPath, journal_dir),
                    "nursery_"
                        ++ integer_to_list(NewSQN)
                        ++ "." ++ ?PENDING_FILEX);
filepath(CompactFilePath, NewSQN, compact_journal) ->
    filename:join(CompactFilePath,
                    "nursery_"
                        ++ integer_to_list(NewSQN)
                        ++ "." ++ ?PENDING_FILEX).

simple_manifest_reader(SQN, RootPath) ->
    ManifestPath = filepath(RootPath, manifest_dir),
    io:format("Opening manifest file at ~s with SQN ~w~n",
                [ManifestPath, SQN]),
    {ok, MBin} = file:read_file(filename:join(ManifestPath,
                                                integer_to_list(SQN)
                                                ++ ".man")),
    binary_to_term(MBin).
    

simple_manifest_writer(Manifest, ManSQN, RootPath) ->
    ManPath = filepath(RootPath, manifest_dir),
    NewFN = filename:join(ManPath,
                            integer_to_list(ManSQN) ++ "." ++ ?MANIFEST_FILEX),
    TmpFN = filename:join(ManPath,
                            integer_to_list(ManSQN) ++ "." ++ ?PENDING_FILEX),
    MBin = term_to_binary(lists:map(fun({SQN, FN, _PID}) -> {SQN, FN} end,
                                        Manifest)),
    case filelib:is_file(NewFN) of
        true ->
            io:format("Error - trying to write manifest for"
                        ++ " ManifestSQN=~w which already exists~n", [ManSQN]),
            error;
        false ->
            io:format("Writing new version of manifest for "
                        ++ " manifestSQN=~w~n", [ManSQN]),
            ok = file:write_file(TmpFN, MBin),
            ok = file:rename(TmpFN, NewFN),
            ok
    end.
    
manifest_printer(Manifest) ->
    lists:foreach(fun(X) ->
                        {SQN, FN} = case X of
                                        {A, B, _PID} ->
                                            {A, B};
                                        {A, B} ->
                                            {A, B}
                                    end,
                            io:format("At SQN=~w journal has filename ~s~n",
                                            [SQN, FN]) end,
                    Manifest).


initiate_penciller_snapshot(Bookie) ->
    {ok,
        {LedgerSnap, LedgerCache},
        _} = leveled_bookie:book_snapshotledger(Bookie, self(), undefined),
    ok = leveled_penciller:pcl_loadsnapshot(LedgerSnap,
                                                gb_trees:to_list(LedgerCache)),
    MaxSQN = leveled_penciller:pcl_getstartupsequencenumber(LedgerSnap),
    {LedgerSnap, MaxSQN}.

%%%============================================================================
%%% Test
%%%============================================================================

-ifdef(TEST).

build_dummy_journal() ->
    RootPath = "../test/journal",
    clean_testdir(RootPath),
    JournalFP = filepath(RootPath, journal_dir),
    ManifestFP = filepath(RootPath, manifest_dir),
    ok = filelib:ensure_dir(RootPath),
    ok = filelib:ensure_dir(JournalFP),
    ok = filelib:ensure_dir(ManifestFP),
    F1 = filename:join(JournalFP, "nursery_1.pnd"),
    {ok, J1} = leveled_cdb:cdb_open_writer(F1),
    {K1, V1} = {"Key1", "TestValue1"},
    {K2, V2} = {"Key2", "TestValue2"},
    ok = leveled_cdb:cdb_put(J1, {1, K1}, term_to_binary({V1, []})),
    ok = leveled_cdb:cdb_put(J1, {2, K2}, term_to_binary({V2, []})),
    {ok, _} = leveled_cdb:cdb_complete(J1),
    F2 = filename:join(JournalFP, "nursery_3.pnd"),
    {ok, J2} = leveled_cdb:cdb_open_writer(F2),
    {K1, V3} = {"Key1", "TestValue3"},
    {K4, V4} = {"Key4", "TestValue4"},
    ok = leveled_cdb:cdb_put(J2, {3, K1}, term_to_binary({V3, []})),
    ok = leveled_cdb:cdb_put(J2, {4, K4}, term_to_binary({V4, []})),
    ok = leveled_cdb:cdb_close(J2),
    Manifest = [{1, "../test/journal/journal_files/nursery_1.cdb"}],
    ManifestBin = term_to_binary(Manifest),
    {ok, MF1} = file:open(filename:join(ManifestFP, "1.man"),
                            [binary, raw, read, write]),
    ok = file:write(MF1, ManifestBin),
    ok = file:close(MF1).


clean_testdir(RootPath) ->
    clean_subdir(filepath(RootPath, journal_dir)),
    clean_subdir(filepath(RootPath, journal_compact_dir)),
    clean_subdir(filepath(RootPath, manifest_dir)).

clean_subdir(DirPath) ->
    ok = filelib:ensure_dir(DirPath),
    {ok, Files} = file:list_dir(DirPath),
    lists:foreach(fun(FN) ->
                        File = filename:join(DirPath, FN),
                        case file:delete(File) of
                            ok -> io:format("Success deleting ~s~n", [File]);
                            _ -> io:format("Error deleting ~s~n", [File])
                        end
                        end,
                    Files).

simple_buildmanifest_test() ->
    RootPath = "../test/journal",
    build_dummy_journal(),
    Res = build_manifest(["1.man"],
                            ["../test/journal/journal_files/nursery_1.cdb",
                                "../test/journal/journal_files/nursery_3.pnd"],
                            fun simple_manifest_reader/2,
                            RootPath),
    io:format("Build manifest output is ~w~n", [Res]),
    {Man, {ActJournal, ActJournalSQN}, HighSQN, ManSQN} = Res,
    ?assertMatch(HighSQN, 4),
    ?assertMatch(ManSQN, 1),
    ?assertMatch([{1, "../test/journal/journal_files/nursery_1.cdb", _}], Man),
    {ActSQN, _ActK} = leveled_cdb:cdb_lastkey(ActJournal),
    ?assertMatch(ActSQN, 4),
    ?assertMatch(ActJournalSQN, 3),
    close_allmanifest(Man, ActJournal),
    clean_testdir(RootPath).

another_buildmanifest_test() ->
    %% There is a rolled jounral file which is not yet in the manifest
    RootPath = "../test/journal",
    build_dummy_journal(),
    FN = filepath(RootPath, 3, new_journal),
    {ok, FileToRoll} = leveled_cdb:cdb_open_writer(FN),
    {ok, _} = leveled_cdb:cdb_complete(FileToRoll),
    FN2 = filepath(RootPath, 5, new_journal),
    {ok, NewActiveJN} = leveled_cdb:cdb_open_writer(FN2),
    {K5, V5} = {"Key5", "TestValue5"},
    {K6, V6} = {"Key6", "TestValue6"},
    ok = leveled_cdb:cdb_put(NewActiveJN, {5, K5}, term_to_binary({V5, []})),
    ok = leveled_cdb:cdb_put(NewActiveJN, {6, K6}, term_to_binary({V6, []})),
    ok = leveled_cdb:cdb_close(NewActiveJN),
    %% Test setup - now build manifest
    Res = build_manifest(["1.man"],
                            ["../test/journal/journal_files/nursery_1.cdb",
                                "../test/journal/journal_files/nursery_3.cdb",
                                "../test/journal/journal_files/nursery_5.pnd"],
                            fun simple_manifest_reader/2,
                            RootPath),
    io:format("Build manifest output is ~w~n", [Res]),
    {Man, {ActJournal, ActJournalSQN}, HighSQN, ManSQN} = Res,
    ?assertMatch(HighSQN, 6),
    ?assertMatch(ManSQN, 1),
    ?assertMatch([{3, "../test/journal/journal_files/nursery_3.cdb", _},
                    {1, "../test/journal/journal_files/nursery_1.cdb", _}], Man),
    {ActSQN, _ActK} = leveled_cdb:cdb_lastkey(ActJournal),
    ?assertMatch(ActSQN, 6),
    ?assertMatch(ActJournalSQN, 5),
    close_allmanifest(Man, ActJournal),
    clean_testdir(RootPath).


empty_buildmanifest_test() ->
    RootPath = "../test/journal",
    Res = build_manifest([],
                            [],
                            fun simple_manifest_reader/2,
                            RootPath),
    io:format("Build manifest output is ~w~n", [Res]),
    {Man, {ActJournal, ActJournalSQN}, HighSQN, ManSQN} = Res,
    ?assertMatch(Man, []),
    ?assertMatch(ManSQN, 0),
    ?assertMatch(HighSQN, 0),
    ?assertMatch(ActJournalSQN, 1),
    empty = leveled_cdb:cdb_lastkey(ActJournal),
    FN = leveled_cdb:cdb_filename(ActJournal),
    %% The filename should be based on the next journal SQN (1) not 0
    ?assertMatch(FN, filepath(RootPath, 1, new_journal)),
    close_allmanifest(Man, ActJournal),
    clean_testdir(RootPath).

simplejournal_test() ->
    %% build up a database, and then open it through the gen_server wrap
    %% Get and Put some keys
    RootPath = "../test/journal",
    build_dummy_journal(),
    {ok, Ink1} = ink_start(#inker_options{root_path=RootPath,
                                            cdb_options=#cdb_options{}}),
    R1 = ink_get(Ink1, "Key1", 1),
    ?assertMatch(R1, {{1, "Key1"}, {"TestValue1", []}}),
    R2 = ink_get(Ink1, "Key1", 3),
    ?assertMatch(R2, {{3, "Key1"}, {"TestValue3", []}}),
    {ok, NewSQN1, _ObjSize} = ink_put(Ink1, "Key99", "TestValue99", []),
    ?assertMatch(NewSQN1, 5),
    R3 = ink_get(Ink1, "Key99", 5),
    io:format("Result 3 is ~w~n", [R3]),
    ?assertMatch(R3, {{5, "Key99"}, {"TestValue99", []}}),
    ink_close(Ink1),
    clean_testdir(RootPath).

rollafile_simplejournal_test() ->
    RootPath = "../test/journal",
    build_dummy_journal(),
    CDBopts = #cdb_options{max_size=300000},
    {ok, Ink1} = ink_start(#inker_options{root_path=RootPath,
                                            cdb_options=CDBopts}),
    FunnyLoop = lists:seq(1, 48),
    {ok, NewSQN1, _ObjSize} = ink_put(Ink1, "KeyAA", "TestValueAA", []),
    ?assertMatch(NewSQN1, 5),
    ok = ink_print_manifest(Ink1),
    R0 = ink_get(Ink1, "KeyAA", 5),
    ?assertMatch(R0, {{5, "KeyAA"}, {"TestValueAA", []}}),
    lists:foreach(fun(X) ->
                        {ok, _, _} = ink_put(Ink1,
                                                "KeyZ" ++ integer_to_list(X),
                                                crypto:rand_bytes(10000),
                                                []) end,
                    FunnyLoop),
    {ok, NewSQN2, _ObjSize} = ink_put(Ink1, "KeyBB", "TestValueBB", []),
    ?assertMatch(NewSQN2, 54),
    ok = ink_print_manifest(Ink1),
    R1 = ink_get(Ink1, "KeyAA", 5),
    ?assertMatch(R1, {{5, "KeyAA"}, {"TestValueAA", []}}),
    R2 = ink_get(Ink1, "KeyBB", 54),
    ?assertMatch(R2, {{54, "KeyBB"}, {"TestValueBB", []}}),
    Man = ink_getmanifest(Ink1),
    FakeMan = [{3, "test", dummy}, {1, "other_test", dummy}],
    ok = ink_updatemanifest(Ink1, FakeMan, Man),
    ?assertMatch(FakeMan, ink_getmanifest(Ink1)),
    ok = ink_updatemanifest(Ink1, Man, FakeMan),
    ?assertMatch({{5, "KeyAA"}, {"TestValueAA", []}},
                    ink_get(Ink1, "KeyAA", 5)),
    ?assertMatch({{54, "KeyBB"}, {"TestValueBB", []}},
                    ink_get(Ink1, "KeyBB", 54)),
    ink_close(Ink1),
    clean_testdir(RootPath).
    
compact_journal_test() ->
    RootPath = "../test/journal",
    build_dummy_journal(),
    CDBopts = #cdb_options{max_size=300000},
    {ok, Ink1} = ink_start(#inker_options{root_path=RootPath,
                                            cdb_options=CDBopts}),
    FunnyLoop = lists:seq(1, 48),
    {ok, NewSQN1, _ObjSize} = ink_put(Ink1, "KeyAA", "TestValueAA", []),
    ?assertMatch(NewSQN1, 5),
    ok = ink_print_manifest(Ink1),
    R0 = ink_get(Ink1, "KeyAA", 5),
    ?assertMatch(R0, {{5, "KeyAA"}, {"TestValueAA", []}}),
    Checker = lists:map(fun(X) ->
                            PK = "KeyZ" ++ integer_to_list(X),
                            {ok, SQN, _} = ink_put(Ink1,
                                                    PK,
                                                    crypto:rand_bytes(10000),
                                                    []),
                            {SQN, PK}
                            end,
                        FunnyLoop),
    {ok, NewSQN2, _ObjSize} = ink_put(Ink1, "KeyBB", "TestValueBB", []),
    ?assertMatch(NewSQN2, 54),
    ActualManifest = ink_getmanifest(Ink1),
    ?assertMatch(2, length(ActualManifest)),
    ok = ink_compactjournal(Ink1,
                            Checker,
                            fun(X) -> {X, 55} end,
                            fun(L, K, SQN) -> lists:member({SQN, K}, L) end,
                            5000),
    timer:sleep(1000),
    CompactedManifest = ink_getmanifest(Ink1),
    ?assertMatch(1, length(CompactedManifest)),
    ink_close(Ink1),
    clean_testdir(RootPath).

-endif.