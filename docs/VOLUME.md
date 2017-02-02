# Volume Testing

## Parallel Node Testing

Initial volume tests have been [based on standard basho_bench eleveldb test](../test/volume/single_node/examples) to run multiple stores in parallel on the same node and and subjecting them to concurrent pressure. 

This showed a relative positive performance for leveled for both population and load:

Populate LevelEd             |  Populate LevelDB
:-------------------------:|:-------------------------:
![](../test/volume/single_node/output/leveled_pop.png "LevelEd - Populate")  |  ![](../test/volume/single_node/output/leveldb_pop.png "LevelDB - Populate")

Load LevelEd             |  Load LevelDB
:-------------------------:|:-------------------------:
![](../test/volume/single_node/output/leveled_load.png "LevelEd - Populate")  |  ![](../test/volume/single_node/output/leveldb_load.png "LevelDB - Populate")


## Riak Cluster Test - #1



## Riak Cluster Test - #2
