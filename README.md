# Sidekiq Heroku Autoscaler

This is a simple [Sidekiq](https://github.com/mperham/sidekiq/) middleware that
works with an [heroku](https://heroku.com) application.

It is used to scale linearly sidekiq processes based on the number of jobs to
be processed.

## Compatibilty

This autoscaler is currently compatible and used with Sidekiq 5.

## Usage

This middleware is to be inserted on the client part of sidekiq, such as:
```
Sidekiq.configure_client do |config|
  if SidekiqHerokuAutoscaler.activated?
    config.client_middleware do |chain|
      chain.add SidekiqHerokuAutoscaler
    end
    SidekiqHerokuAutoscaler.scale_workers # Scale workers on startup
  end
end
```
This will enable the autoscaler, and also scale workers once on startup (for
instance if a job is planned while the autoscaler is not deployed or if the
application in maintenance mode while a job is inserted).

This should be associated to a cron-like service, such as ruby's `clockwork`
for instance, to regularly retrigger the scaling and downscale workers if not
in use.
```
module Clockwork
  if SidekiqHerokuAutoscaler.activated?
    every(ENV.fetch('SIDEKIQ_HEROKU_AUTOSCALER_PERIOD', '5').to_i.minutes, 'Scale sidekiq heroku workers') do
      SidekiqHerokuAutoscaler.scale_workers
    end
  end
end
```

### Configuration

The associated variables are the following ones:
* SIDEKIQ_HEROKU_AUTOSCALER_MIN_WORKERS: minimum number of workers to keep, can
  be overriden on init. Default to 5.
* SIDEKIQ_HEROKU_AUTOSCALER_MAX_WORKERS: maximum number of workers to keep, can
  be overriden on init. Default to 1.
* SIDEKIQ_CONCURRENCY: number of parallel jobs sidekiq can process with 1
  instance, can be overriden on init. Default to 7.
* HEROKU_ACCESS_TOKEN: Heroku API access token to trigger the scaling.
* HEROKU_ENV: indicates the autoscaler can be used (only works on heroku).
* HEROKU_APP_NAME: the Heroku application name, needed for the scaling API calls.
* SIDEKIQ_HEROKU_AUTOSCALER_PERIOD: the number of seconds between two scalings.
  Default to 5 minutes.

The initialization accepts the following arguments as a hash:
* min_workers (see above)
* max_workers (see above)
* type: the dyno type used on heroku (default to `background`)
* worker_capacity (see above)

### Requirements

This requires, on top of sidekiq, the
[platform-api](https://github.com/heroku/platform-api) gem.

The [raven](https://github.com/getsentry/raven-ruby) gem is also used in the
`rescue` to send any error to Sentry.

### Note

This will only work for jobs inserted from the client-side (rails server,
console...). If the sidekiq worker is supposed to insert jobs itself (for
instance a job triggering other jobs), the autoscaler must be inserted in the
server configuration:
```
Sidekiq.configure_server do |config|
  if SidekiqHerokuAutoscaler.activated?
    config.client_middleware do |chain|
      chain.add SidekiqHerokuAutoscaler
    end
    SidekiqHerokuAutoscaler.scale_workers # Scale workers on startup
  end
end
```

## How it works

### Maintenance mode

The autoscaler will not scale if the application is in maintenance mode. This
is to prevent any sidekiq workers to pop up in case of a deployment that
manually downscaled all dynos but could schedul jobs.

### Autoscaler period

The autoscaler assumes it will scale workers every
`SIDEKIQ_HEROKU_AUTOSCALER_PERIOD` seconds. This is needed so it can compute
the number of planned/retried jobs that are supposed to be processed before the
next scaling.

### Target number of workers

The autoscaler will retrieve the following number of jobs:
* currently processed jobs (`ProcessSet`, sum of busy processes)
* pending jobs (Queue, sum of all queues)
* retried jobs (`RetrySet`, using redis score to determine the retry date as is
  done by sidekiq)
* scheduled jobs (`ScheduledSet`, using redis score too)

In the case the scaling was called when adding a job (hence the sidekiq client
configuration), 1 job is added to the total to make sure we have at least 1
worker to process the job (`ProcessSet` potentially having a few seconds delay,
not real-time).

Then, based on the number of parallel job processing, it scales up or down the
Sidekiq workers by calling the Heroku API (setting the application formation).

## Thanks

This is based on the idea from [JustinLove's
autoscaler](https://github.com/JustinLove/autoscaler).

I wanted to get something much simpler only to have a linear scaling based on
the number of jobs that are to be processed.
