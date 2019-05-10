class SidekiqHerokuAutoscaler
  @@options = {
    min_workers: ENV.fetch('SIDEKIQ_HEROKU_AUTOSCALER_MIN_WORKERS', '1').to_i,
    max_workers: ENV.fetch('SIDEKIQ_HEROKU_AUTOSCALER_MAX_WORKERS', '5').to_i,
    type: 'background',
    worker_capacity: ENV.fetch('SIDEKIQ_CONCURRENCY', '7').to_i
  }

  HEROKU_ACCESS_TOKEN = ENV['HEROKU_ACCESS_TOKEN']
  HEROKU_ENV = ENV.fetch('HEROKU_ENV', 'false')

  # @param [Hash] options
  #  * min_workers: minimum amount of workers to spin up
  #  * max_workers: maximum amount of workers to spin up
  #  * type: type of heroku dyno to scale (default: 'background')
  #  * worker_capacity: the amount of jobs one worker can handle
  def initialize(options = {})
    @@options.merge!(options)
  end

  # @param [String, Class] worker_class the string or class of the worker class being enqueued
  # @param [Hash] job the full job payload
  #   * @see https://github.com/mperham/sidekiq/wiki/Job-Format
  # @param [String] queue the name of the queue the job was pulled from
  # @param [ConnectionPool] redis_pool the redis pool
  # @return [Hash, FalseClass, nil] if false or nil is returned,
  #   the job is not to be enqueued into redis, otherwise the block's
  #   return value is returned
  # @yield the next middleware in the chain or the enqueuing of the job
  def call(worker_class, job, queue, redis_pool)
    Thread.new { SidekiqHerokuAutoscaler.scale_workers(true) }
    yield
  end

  def self.scale_workers(adding_job = false)
    if !self.activated?
      return
    end
    @@heroku ||= PlatformAPI.connect_oauth(HEROKU_ACCESS_TOKEN)
    if @@heroku.app.info(ENV.fetch('HEROKU_APP_NAME'))['maintenance']
      puts 'Heroku sidekiq autoscaling: skipping due to maintenance'
      return
    end
    boundary = ENV.fetch('SIDEKIQ_HEROKU_AUTOSCALER_PERIOD', '5').to_i.minutes.from_now.utc.to_f
    # Retrieve jobs being currently processed, that is busy processes
    jobs = Sidekiq::ProcessSet.new.inject(0) { |sum, p| sum + p['busy'] }
    # Retrieve jobs in queue, waiting to be processed
    jobs += Sidekiq::Queue.all.inject(0) { |sum, q| sum + q.size }
    # Both retried and scheduled jobs are stored using redis score to determine
    # the timestamp after which the job is supposed to be processed.
    # Retrieve jobs soon to be retried after a failure
    jobs += Sidekiq::RetrySet.new.select { |s| s.score < boundary }.length
    # Retrieve scheduled jobs soon to be started
    jobs += Sidekiq::ScheduledSet.new.select { |s| s.score < boundary }.length
    if adding_job
      # Note: ProcessSet may have up to 5 seconds of delay with actual number of
      # processes (not real-time data)
      # If adding a new job, this may be called before the job is actually added to
      # the queue. Having one extra worker for the autoscaling period is better
      # than not enough workers.
      jobs += 1
    end
    target_worker_size = (jobs / @@options[:worker_capacity].to_f).ceil
    target_worker_size = target_worker_size.clamp(@@options[:min_workers], @@options[:max_workers])
    if target_worker_size != Sidekiq::ProcessSet.new.size
      puts "Heroku sidekiq autoscaling: scale to #{target_worker_size} worker(s)"
      @@heroku.formation.update(ENV.fetch('HEROKU_APP_NAME'), @@options[:type], {
        quantity: target_worker_size
      })
    end
  rescue StandardError => e
    puts "Sidekiq Heroku autoscaling: failed to scale workers: #{e}"
    Raven.capture_message(
      'Sidekiq Heroku autoscaling error',
      extra: {
        error: e.message
      }
    )
  end

  def self.activated?
    return HEROKU_ENV == 'true' && HEROKU_ACCESS_TOKEN.present?
  end
end
