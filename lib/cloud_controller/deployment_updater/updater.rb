require 'cloud_controller/deployment_updater/actions/scale'
require 'cloud_controller/deployment_updater/actions/cancel'
require 'cloud_controller/deployment_updater/actions/finalize'

module VCAP::CloudController
  module DeploymentUpdater
    class Updater
      attr_reader :deployment, :logger

      def initialize(deployment, logger)
        @deployment = deployment
        @logger = logger
      end

      def scale
        with_error_logging('error-scaling-deployment') do
          finished = Actions::Scale.new(deployment, logger, deployment.desired_web_instances).call
          Actions::Finalize.new(deployment).call if finished
          logger.info("ran-deployment-update-for-#{deployment.guid}")
        end
      end

      def canary
        with_error_logging('error-canarying-deployment') do
          finished = Actions::Scale.new(deployment, logger, deployment.canary_total_instances, deployment.current_canary_instance_target).call
          if finished
            deployment.update(
              last_healthy_at: Time.now,
              state: DeploymentModel::PAUSED_STATE,
              status_value: DeploymentModel::ACTIVE_STATUS_VALUE,
              status_reason: DeploymentModel::PAUSED_STATUS_REASON
            )
            logger.info("paused-canary-deployment-for-#{deployment.guid}")
          end
          logger.info("ran-canarying-deployment-for-#{deployment.guid}")
        end
      end

      def cancel
        with_error_logging('error-canceling-deployment') do
          Actions::Cancel.new(deployment, logger).call
          logger.info("ran-cancel-deployment-for-#{deployment.guid}")
        end
      end

      private

      APPROVED_ERRORS = [
        Sequel::ValidationFailed,
        CloudController::Errors::ApiError
      ].freeze

      def with_error_logging(error_message)
        yield
      rescue StandardError => e
        error_name = e.is_a?(CloudController::Errors::ApiError) ? e.name : e.class.name

        begin
          if APPROVED_ERRORS.include?(e.class)
            deployment.update(error: e.message)
          else
            deployment.update(error: 'An unexpected error has occurred.')
          end
        rescue StandardError => new_error
          logger.error(
            'error-saving-deployment-error',
            deployment_guid: deployment.guid,
            error: new_error.class.name,
            error_message: new_error.message,
            backtrace: new_error.backtrace.join("\n")
          )
        end

        logger.error(
          error_message,
          deployment_guid: deployment.guid,
          error: error_name,
          error_message: e.message,
          backtrace: e.backtrace.join("\n")
        )
      end
    end
  end
end
