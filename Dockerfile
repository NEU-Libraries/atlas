FROM ruby:3.0-slim
# update the repository sources list
# and install dependencies
RUN apt-get update \
    && apt-get install -y nodejs curl git build-essential libpq-dev libmagic-dev \
    && apt-get -y autoremove \
    && apt-get -y clean

RUN curl -L https://codeclimate.com/downloads/test-reporter/test-reporter-latest-linux-amd64 > /usr/local/bin/cc-test-reporter
RUN chmod +x /usr/local/bin/cc-test-reporter

RUN useradd -ms /bin/bash atlas
USER atlas

RUN mkdir -p /home/atlas/storage

COPY --chown=atlas:atlas Gemfile* /tmp/
WORKDIR /tmp
RUN bundle install -j8

RUN mkdir -p /home/atlas/web
WORKDIR /home/atlas/web

RUN echo "IRB.conf[:USE_AUTOCOMPLETE] = false" > /home/atlas/.irbrc

RUN git config --global --add safe.directory /home/atlas/web
COPY --chown=atlas:atlas . /home/atlas/web
