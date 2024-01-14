Proof of concept of a sp runner as a redis lua script.
-----

How to run
====

```
# Build dockerfile
docker build -t sp_redis .
# Start redis server
docker run -v ./src:/src --name sp_redis -p 6379:6379 -p 8001:8001 sp_redis

# Load runner lua function
docker exec -it sp_redis /bin/bash
cat /src/runner.lua | redis-cli -x FUNCTION LOAD REPLACE
exit

# Start a ticker (tick every 100ms)
docker exec -it sp_redis redis-cli
> TIMER.NEW ticker tick 100 LOOP 0
> exit

```
Open <http://localhost:8001/> to look at the state.


Dependencies
====
Uses https://github.com/tzongw/redis-timer for ticking (included for easy cloning)
