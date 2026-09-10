FROM ruby:latest

WORKDIR /app

COPY . .

RUN apt-get update && apt-get install -y build-essential libpq-dev nodejs

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash -

ARG GIT_SHA
ARG RAILS_MASTER_KEY
ENV GIT_SHA=$GIT_SHA

RUN bundle install

RUN APP_ENV=production APP_DEBUG=false APP_A=1 APP_B=2 APP_C=3 APP_D=4 APP_E=5 APP_F=6 APP_G=7 APP_H=8 APP_I=9 APP_J=10 APP_K=11 APP_L=12 APP_M=13 APP_N=14 APP_O=15 APP_P=16 APP_Q=17 APP_R=18 APP_S=19 APP_T=20 ./bin/setup

CMD ["./bin/rails", "server"]
