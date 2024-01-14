FROM redis/redis-stack

RUN apt-get -y update
RUN apt-get install -y build-essential

WORKDIR /app

COPY ./redis-timer ./redis-timer
RUN cd redis-timer && make

COPY redis.conf /usr/local/etc/redis/redis.conf


COPY ./entrypoint.sh ./entrypoint.sh
RUN chmod a+x ./entrypoint.sh

CMD ["./entrypoint.sh"]

# CMD [ "redis-server", "/usr/local/etc/redis/redis.conf", "--loadmodule /app/redis-timer/timer.so" ]
