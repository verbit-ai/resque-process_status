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

          # NOTE: this callback will be defined if workers extends Resque::Plugins::Retry
          if base.respond_to?(:try_again_callback)
            base.try_again_callback { |_exception, vars|
              on_retry_track_retries(vars.fetch('PROCESS_ID'))
            }
          end
        end
      end

      private

      def set_status(**args)
        self.class.set_status(process_id, **args)
      end

      # Callbacks and helper methods for a workers
      module ClassMethods
        ### Callbacks

        def after_enqueue_track_status(vars)
          set_status(vars.fetch('PROCESS_ID'),
                     vars: vars, class: self.to_s, created_at: Time.now.to_s, status: :queued)
        end

        def before_perform_track_status(vars)
          set_status(vars.fetch('PROCESS_ID'), started_at: Time.now.to_s, status: :working)
        end

        # NOTE: will be called before the on_failure callback
        def on_retry_track_retries(process_id)
          details = describe(process_id)
          retry_item = details.slice(:created_at, :started_at).merge(failed_at: Time.now.to_s)

          set_status(process_id, retries: details.fetch(:retries, []).push(retry_item))
        end

        def on_failure_track_status(_e, vars)
          set_status(vars.fetch('PROCESS_ID'), failed_at: Time.now.to_s, status: :failed)
        end

        def after_perform_track_status(vars)
          set_status(vars.fetch('PROCESS_ID'), stopped_at: Time.now.to_s, status: :completed)
        end

        ### Helper methods

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
