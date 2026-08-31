FROM ruby:3.4-slim
# update the repository sources list
# and install dependencies
RUN apt-get update \
    && apt-get install -y nodejs curl git build-essential libpq-dev \
    && apt-get -y autoremove \
    && apt-get -y clean

RUN curl -L https://codeclimate.com/downloads/test-reporter/test-reporter-latest-linux-amd64 > /usr/local/bin/cc-test-reporter
RUN chmod +x /usr/local/bin/cc-test-reporter

# YJIT, with an explicit memory cap. The cap is not a detail: measured across
# the read path, 32MB runs ~20% faster than the interpreter, while YJIT's
# default 128MB compiles so much code that the added GC gives most of that
# back. Below 16MB it thrashes and loses to the interpreter outright.
ENV RUBYOPT="--yjit --yjit-mem-size=32"

RUN useradd -ms /bin/bash atlas
USER atlas

# Each storage root's path must exist here, owned by atlas. Docker seeds a fresh
# named volume from the image's content at the mount path, ownership included; a
# path absent from the image gets a root-owned volume the app cannot write to,
# and the pool only discovers it when the previous root seals.
RUN mkdir -p /home/atlas/storage /home/atlas/storage-r002

COPY --chown=atlas:atlas Gemfile* /tmp/
WORKDIR /tmp
RUN bundle install -j8

RUN mkdir -p /home/atlas/web
WORKDIR /home/atlas/web

RUN echo "IRB.conf[:USE_AUTOCOMPLETE] = false" > /home/atlas/.irbrc

RUN git config --global --add safe.directory /home/atlas/web
COPY --chown=atlas:atlas . /home/atlas/web
