# frozen_string_literal: true

require 'resque'
require 'json'

module Resque
  module Plugins
    # Plugin to track status of resque workers into redis.
    #
    # NOTE: Every worker which included this plugin should to have one argument which include key
    # "PROCESS_ID".
    # Also every instance should to implement "process_id", reader for this "PROCESS_ID"
    module ProcessStatus
      REDIS_KEY = 'ecs_process:status:%{process_id}'

      class << self
        def included(base)
          base.extend ClassMethods
        end
      end

      private

      def set_status(**args)
        self.class.set_status(process_id, **args)
      end

      # Callbacks and helper methods for a workers
      module ClassMethods
        def after_enqueue_track_status(vars)
          set_status(vars.fetch('PROCESS_ID'),
                     vars: vars, class: self.to_s, start_at: Time.now.to_s, status: :queued)
        end

        def before_perform_track_status(vars)
          set_status(vars.fetch('PROCESS_ID'), perform_at: Time.now.to_s, status: :working)
        end

        def on_failure_track_status(_e, vars)
          set_status(vars.fetch('PROCESS_ID'), failed_at: Time.now.to_s, status: :failed)
        end

        def after_perform_track_status(vars)
          set_status(vars.fetch('PROCESS_ID'), end_at: Time.now.to_s, status: :completed)
        end

        def set_status(process_id, **args)
          Resque.redis.setex(REDIS_KEY % {process_id: process_id},
                             24 * 3600,
                             (describe(process_id) || {}).merge(args).to_json)
        end

        def describe(process_id)
          Resque.redis.get(REDIS_KEY % {process_id: process_id}).then { |val|
            next unless val

            JSON.parse(val, symbolize_names: true)
          }
        end
      end
    end
  end
end
