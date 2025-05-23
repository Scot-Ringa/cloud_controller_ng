require 'cloud_controller/diego/lifecycles/buildpack_info'
require 'fetchers/buildpack_lifecycle_fetcher'

module VCAP::CloudController
  class LifecycleBase
    attr_reader :staging_message, :buildpack_infos

    def initialize(package, staging_message)
      @staging_message = staging_message
      @package = package

      db_result = BuildpackLifecycleFetcher.fetch(buildpacks_to_use, staging_stack, type)
      @buildpack_infos = db_result[:buildpack_infos]
      @validator = BuildpackLifecycleDataValidator.new({ buildpack_infos: buildpack_infos, stack: db_result[:stack] })
    end

    delegate :valid?, :errors, to: :validator

    def staging_stack
      requested_stack || app_stack || VCAP::CloudController::Stack.default.name
    end

    private

    def buildpacks_to_use
      staging_message.buildpack_data.buildpacks || @package.app.lifecycle_data.buildpacks
    end

    def requested_stack
      @staging_message.buildpack_data.stack
    end

    attr_reader :validator
  end
end
