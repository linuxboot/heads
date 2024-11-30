FROM debian:bullseye

COPY docker/ docker/

# There;s a scary error about some frontend not being initialized, but it seems
# harmless.  Not going to bother to fix for a tech demo.  More info
# https://github.com/moby/moby/issues/27988
RUN apt-get update && apt-get install -y apt-utils
RUN apt-get update && apt-get install -y $(cat docker/dependencies.txt)

RUN echo "Build environment initialized"
