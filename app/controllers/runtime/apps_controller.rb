require 'presenters/system_environment/system_env_presenter'
require 'fetchers/queries/app_query'
require 'actions/v2/app_stage'
require 'actions/v2/app_create'
require 'actions/v2/app_update'
require 'actions/v2/route_mapping_create'
require 'models/helpers/process_types'
require 'controllers/runtime/mixins/find_process_through_app'

module VCAP::CloudController
  class AppsController < RestController::ModelController
    include FindProcessThroughApp

    model_class_name :ProcessModel
    self.not_found_exception_name = 'AppNotFound'

    VCAP::CloudController.set_controller_for_model_name(
      model_name: 'ProcessModel',
      controller: self
    )

    def self.dependencies
      %i[app_event_repository droplet_blobstore stagers upload_handler]
    end

    define_attributes do
      attribute :enable_ssh, Message::Boolean, default: nil
      attribute :buildpack, String, default: nil
      attribute :command, String, default: nil
      attribute :console, Message::Boolean, default: false
      attribute :diego, Message::Boolean, default: nil
      attribute :docker_image, String, default: nil
      attribute :docker_credentials, Hash, default: {}
      attribute :debug, String, default: nil
      attribute :disk_quota, Integer, default: nil
      attribute :log_rate_limit, Integer, default: nil
      attribute :environment_json, Hash, default: {}, redact_in: %i[create update]
      attribute :health_check_http_endpoint, String, default: nil
      attribute :health_check_type, String, default: 'port'
      attribute :health_check_timeout, Integer, default: nil
      attribute :instances, Integer, default: 1
      attribute :memory, Integer, default: nil
      attribute :name, String
      attribute :production, Message::Boolean, default: false
      attribute :state, String, default: 'STOPPED'
      attribute :detected_start_command, String, exclude_in: %i[create update]
      attribute :ports, [Integer], default: nil

      to_one :space
      to_one :stack, optional_in: :create

      to_many :routes, exclude_in: %i[create update], route_for: :get
      to_many :events, exclude_in: %i[create update], link_only: true
      to_many :service_bindings, exclude_in: %i[create update], route_for: [:get]
      to_many :route_mappings, exclude_in: %i[create update], link_only: true, route_for: :get, association_controller: :RouteMappingsController
    end

    query_parameters :name, :space_guid, :organization_guid, :diego, :stack_guid

    get '/v2/apps/:guid/env', :read_env

    def read_env(guid)
      FeatureFlag.raise_unless_enabled!(:env_var_visibility)
      process = find_guid_and_validate_access(:read_env, guid, ProcessModel)
      FeatureFlag.raise_unless_enabled!(:space_developer_env_var_visibility)

      vcap_application = VCAP::VarsBuilder.new(process).to_hash

      [
        HTTP::OK,
        Oj.dump({
                  staging_env_json: EnvironmentVariableGroup.staging.environment_json,
                  running_env_json: EnvironmentVariableGroup.running.environment_json,
                  environment_json: process.app.environment_variables,
                  system_env_json: SystemEnvPresenter.new(process).system_env,
                  application_env_json: { 'VCAP_APPLICATION' => vcap_application }
                }, mode: :compat)
      ]
    end

    def self.translate_validation_exception(e, attributes)
      space_and_name_errors     = e.errors.on(%i[space_guid name])
      memory_errors             = e.errors.on(:memory)
      instance_number_errors    = e.errors.on(:instances)
      app_instance_limit_errors = e.errors.on(:app_instance_limit)
      state_errors              = e.errors.on(:state)
      docker_errors             = e.errors.on(:docker)

      if space_and_name_errors
        CloudController::Errors::ApiError.new_from_details('AppNameTaken', attributes['name'])
      elsif memory_errors
        translate_memory_validation_exception(memory_errors)
      elsif instance_number_errors
        CloudController::Errors::ApiError.new_from_details('AppInvalid', 'Number of instances less than 0')
      elsif app_instance_limit_errors
        if app_instance_limit_errors.include?(:space_app_instance_limit_exceeded)
          CloudController::Errors::ApiError.new_from_details('SpaceQuotaInstanceLimitExceeded')
        else
          CloudController::Errors::ApiError.new_from_details('QuotaInstanceLimitExceeded')
        end
      elsif state_errors
        CloudController::Errors::ApiError.new_from_details('AppInvalid', 'Invalid app state provided')
      elsif docker_errors && docker_errors.include?(:docker_disabled)
        CloudController::Errors::ApiError.new_from_details('DockerDisabled')
      else
        CloudController::Errors::ApiError.new_from_details('AppInvalid', e.errors.full_messages)
      end
    end

    def self.translate_memory_validation_exception(memory_errors)
      if memory_errors.include?(:space_quota_exceeded)
        CloudController::Errors::ApiError.new_from_details('SpaceQuotaMemoryLimitExceeded', 'app requested more memory than available')
      elsif memory_errors.include?(:space_instance_memory_limit_exceeded)
        CloudController::Errors::ApiError.new_from_details('SpaceQuotaInstanceMemoryLimitExceeded')
      elsif memory_errors.include?(:quota_exceeded)
        CloudController::Errors::ApiError.new_from_details('AppMemoryQuotaExceeded', 'app requested more memory than available')
      elsif memory_errors.include?(:zero_or_less)
        CloudController::Errors::ApiError.new_from_details('AppMemoryInvalid')
      elsif memory_errors.include?(:instance_memory_limit_exceeded)
        CloudController::Errors::ApiError.new_from_details('QuotaInstanceMemoryLimitExceeded')
      elsif memory_errors.include?(:process_memory_insufficient_for_sidecars)
        CloudController::Errors::ApiError.new_from_details('AppMemoryInsufficientForSidecars')
      end
    end

    def self.url_for_guid(_, process)
      super(process.app_guid, process)
    end

    def inject_dependencies(dependencies)
      super
      @app_event_repository = dependencies.fetch(:app_event_repository)
      @blobstore            = dependencies.fetch(:droplet_blobstore)
      @stagers              = dependencies.fetch(:stagers)
      @upload_handler       = dependencies.fetch(:upload_handler)
    end

    def delete(guid)
      process = find_guid_and_validate_access(:delete, guid)
      space   = process.space

      if !recursive_delete? && process.service_bindings.present?
        raise CloudController::Errors::ApiError.new_from_details('AssociationNotEmpty', 'service_bindings',
                                                                 process.class.table_name)
      end

      begin
        AppDelete.new(UserAuditInfo.from_context(SecurityContext)).delete_without_event([process.app])
      rescue Sequel::NoExistingObject
        raise self.class.not_found_exception(guid, AppModel)
      rescue AppDelete::SubResourceError => e
        error_message = e.underlying_errors.map { |err| "\t" + err.message }.join("\n")
        raise CloudController::Errors::ApiError.new_from_details('AppRecursiveDeleteFailed', process.app.name, error_message)
      end

      @app_event_repository.record_app_delete_request(
        process,
        space,
        UserAuditInfo.from_context(SecurityContext),
        recursive_delete?
      )

      TelemetryLogger.v2_emit(
        'delete-app',
        {
          'app-id' => process.app_guid,
          'user-id' => current_user.guid
        }
      )

      [HTTP::NO_CONTENT, nil]
    end

    get '/v2/apps/:guid/droplet/download', :download_droplet

    def download_droplet(guid)
      process = find_guid_and_validate_access(:read, guid)
      blob_dispatcher.send_or_redirect(guid: process.desired_droplet.try(:blobstore_key))
    rescue CloudController::Errors::BlobNotFound
      raise CloudController::Errors::ApiError.new_from_details('ResourceNotFound', "Droplet not found for app with guid #{process.guid}")
    end

    put '/v2/apps/:guid/droplet/upload', :upload_droplet

    def upload_droplet(guid)
      process      = find_guid_and_validate_access(:update, guid)
      droplet_path = @upload_handler.uploaded_file(request.POST, 'droplet')

      unless droplet_path
        missing_resources_message = 'missing :droplet_path'
        raise CloudController::Errors::ApiError.new_from_details('DropletUploadInvalid', missing_resources_message)
      end

      enqueued_job = nil
      DropletModel.db.transaction do
        droplet = DropletModel.create(app: process.app, state: DropletModel::PROCESSING_UPLOAD_STATE)
        BuildpackLifecycleDataModel.create(droplet:)

        droplet_upload_job = Jobs::V2::UploadDropletFromUser.new(droplet_path, droplet.guid)
        enqueued_job       = Jobs::Enqueuer.new(queue: Jobs::Queues.local(config)).enqueue(droplet_upload_job)
      end

      [HTTP::CREATED, JobPresenter.new(enqueued_job).to_json]
    end

    def read(guid)
      process = find_guid(guid)
      raise CloudController::Errors::ApiError.new_from_details('AppNotFound', guid) unless process.web?

      validate_access(:read, process)
      object_renderer.render_json(self.class, process, @opts)
    end

    def self.filter_dataset(dataset)
      dataset_by_web = dataset.where(type: ProcessTypes::WEB)
      dataset_by_web.exclude(guid: duplicated_older_process_guids(dataset_by_web)).qualify(ProcessModel.table_name)
    end

    def self.duplicated_older_process_guids(dataset)
      # Details at https://groups.google.com/d/msg/sequel-talk/wVuTgcCk2gw/VlPVVI2SBgAJ
      ProcessModel.db.from(dataset.as(:p1), dataset.as(:p2)).
        where do
          (p1[:app_guid] =~ p2[:app_guid]) &
            ((p1[:created_at] < p2[:created_at]) |
              ((p1[:created_at] =~ p2[:created_at]) & (p1[:id] < p2[:id])))
        end.
        distinct.select { p1[:guid] }
    end

    private

    def filter_dataset(dataset)
      self.class.filter_dataset(dataset)
    end

    def user_audit_info
      @user_audit_info ||= UserAuditInfo.from_context(SecurityContext)
    end

    def blob_dispatcher
      BlobDispatcher.new(blobstore: @blobstore, controller: self)
    end

    def before_update(app)
      verify_enable_ssh(app.space)
      updated_diego_flag = request_attrs['diego']
      ports              = request_attrs['ports']
      ignore_empty_ports! if ports == []
      return unless should_warn_about_changed_ports?(app.diego, updated_diego_flag, ports)

      add_warning('App ports have changed but are unknown. The app should now listen on the port specified by environment variable PORT.')
    end

    def ignore_empty_ports!
      @request_attrs = @request_attrs.deep_dup
      @request_attrs.delete 'ports'
      @request_attrs.freeze
    end

    def should_warn_about_changed_ports?(old_diego, new_diego, ports)
      !new_diego.nil? && old_diego && !new_diego && ports.nil?
    end

    def verify_enable_ssh(space)
      app_enable_ssh   = request_attrs['enable_ssh']
      global_allow_ssh = VCAP::CloudController::Config.config.get(:allow_app_ssh_access)
      ssh_allowed      = global_allow_ssh && (space.allow_ssh || roles.admin?)

      return unless app_enable_ssh && !ssh_allowed

      raise CloudController::Errors::ApiError.new_from_details(
        'InvalidRequest',
        'enable_ssh must be false due to global allow_ssh setting'
      )
    end

    def after_update(app)
      stager_response = app.last_stager_response
      set_header('X-App-Staging-Log', stager_response.streaming_log_url) if stager_response.respond_to?(:streaming_log_url) && stager_response.streaming_log_url

      @app_event_repository.record_app_update(app, app.space, user_audit_info, request_attrs)
    end

    def update(guid)
      json_msg       = self.class::UpdateMessage.decode(body)
      @request_attrs = json_msg.extract(stringify_keys: true)
      logger.debug 'cc.update', guid: guid, attributes: redact_attributes(:update, request_attrs)
      raise InvalidRequest unless request_attrs

      process = find_guid(guid)
      app     = process.app

      before_update(process)

      updater = V2::AppUpdate.new(access_validator: self, stagers: @stagers)
      updater.update(app, process, request_attrs)

      after_update(process)

      TelemetryLogger.v2_emit(
        'update-app',
        {
          'app-id' => process.app_guid,
          'user-id' => current_user.guid
        }
      )

      if %w[instances memory disk_quota].any? { |k| @request_attrs.key?(k) }
        TelemetryLogger.v2_emit(
          'scale-app',
          {
            'app-id' => process.app_guid,
            'user-id' => current_user.guid
          },
          {
            'instance-count' => process.instances,
            'memory-in-mb' => process.memory,
            'disk-in-mb' => process.disk_quota,
            'process-type' => process.type
          }
        )
      end

      if @request_attrs.key?('state')
        if @request_attrs['state'] == 'STARTED'
          TelemetryLogger.v2_emit(
            'start-app',
            {
              'app-id' => process.app_guid,
              'user-id' => current_user.guid
            }
          )
        end
        if @request_attrs['state'] == 'STOPPED'
          TelemetryLogger.v2_emit(
            'stop-app',
            {
              'app-id' => process.app_guid,
              'user-id' => current_user.guid
            }
          )
        end
      end

      [HTTP::CREATED, object_renderer.render_json(self.class, process, @opts)]
    rescue PackageCreate::InvalidPackage => e
      unprocessable!(e.message)
    end

    def create
      @request_attrs = self.class::CreateMessage.decode(body).extract(stringify_keys: true)
      logger.debug 'cc.create', model: self.class.model_class_name, attributes: redact_attributes(:create, request_attrs)

      space = find_guid(request_attrs['space_guid'], Space)
      verify_enable_ssh(space)

      creator = V2::AppCreate.new(access_validator: self)
      process = creator.create(request_attrs)

      @app_event_repository.record_app_create(
        process,
        process.space,
        user_audit_info,
        request_attrs
      )

      TelemetryLogger.v2_emit(
        'create-app',
        {
          'app-id' => process.app_guid,
          'user-id' => current_user.guid
        }
      )

      [
        HTTP::CREATED,
        { 'Location' => "#{self.class.path}/#{process.guid}" },
        object_renderer.render_json(self.class, process, @opts)
      ]
    rescue PackageCreate::InvalidPackage => e
      unprocessable!(e.message)
    end

    put '/v2/apps/:app_guid/routes/:route_guid', :add_route

    def add_route(app_guid, route_guid)
      logger.debug 'cc.association.add', guid: app_guid, association: 'routes', other_guid: route_guid
      @request_attrs = { 'route' => route_guid, verb: 'add', relation: 'routes', related_guid: route_guid }

      process = find_guid(app_guid, ProcessModel)
      validate_access(:read_related_object_for_update, process, request_attrs)

      before_update(process)

      route = Route.find(guid: request_attrs['route'])
      raise CloudController::Errors::ApiError.new_from_details('RouteNotFound', route_guid) unless route

      begin
        V2::RouteMappingCreate.new(user_audit_info, route, process, request_attrs, logger).add
      rescue ::VCAP::CloudController::V2::RouteMappingCreate::DuplicateRouteMapping
        # the route is already mapped, consider the request successful
      rescue ::VCAP::CloudController::V2::RouteMappingCreate::RoutingApiDisabledError
        raise CloudController::Errors::ApiError.new_from_details('RoutingApiDisabled')
      rescue ::VCAP::CloudController::V2::RouteMappingCreate::SpaceMismatch
        raise CloudController::Errors::InvalidRelation.new(
          'The app cannot be mapped to this route because the route is not in this space. Apps must be mapped to routes in the same space.'
        )
      end

      after_update(process)

      [HTTP::CREATED, object_renderer.render_json(self.class, process, @opts)]
    end

    delete '/v2/apps/:app_guid/routes/:route_guid', :remove_route

    def remove_route(app_guid, route_guid)
      logger.debug 'cc.association.remove', guid: app_guid, association: 'routes', other_guid: route_guid
      @request_attrs = { 'route' => route_guid, verb: 'remove', relation: 'routes', related_guid: route_guid }

      process = find_guid(app_guid, ProcessModel)
      validate_access(:can_remove_related_object, process, request_attrs)

      before_update(process)

      route = Route.find(guid: request_attrs['route'])
      raise CloudController::Errors::ApiError.new_from_details('RouteNotFound', route_guid) unless route

      route_mapping = RouteMappingModel.find(app: process.app, route: route, process: process)
      RouteMappingDelete.new(user_audit_info).delete(route_mapping)

      after_update(process)

      [HTTP::NO_CONTENT]
    end

    deprecated_endpoint '/v2/apps/:app_guid/service_bindings/:service_binding_guid'
    delete '/v2/apps/:app_guid/service_bindings/:service_binding_guid', :remove_service_binding

    def remove_service_binding(app_guid, service_binding_guid)
      logger.debug 'cc.association.remove', guid: app_guid, association: 'service_bindings', other_guid: service_binding_guid
      @request_attrs = { 'service_binding' => service_binding_guid, verb: 'remove', relation: 'service_bindings', related_guid: service_binding_guid }

      process = find_guid(app_guid, ProcessModel)
      validate_access(:can_remove_related_object, process, request_attrs)

      before_update(process)

      service_binding = ServiceBinding.find(guid: request_attrs['service_binding'])
      raise CloudController::Errors::ApiError.new_from_details('ServiceBindingNotFound', service_binding_guid) unless service_binding

      ServiceBindingDelete.new(UserAuditInfo.from_context(SecurityContext)).foreground_delete_request(service_binding)

      after_update(process)

      [HTTP::NO_CONTENT]
    end

    get '/v2/apps/:guid/permissions', :permissions

    def permissions(guid)
      find_guid_and_validate_access(:read_permissions, guid, ProcessModel)

      [HTTP::OK, Oj.dump({
                           read_sensitive_data: true,
                           read_basic_data: true
                         }, mode: :compat)]
    rescue CloudController::Errors::ApiError => e
      raise e unless e.name == 'NotAuthorized'

      process = find_guid(guid, ProcessModel)
      membership = VCAP::CloudController::Membership.new(current_user)

      basic_access = [
        VCAP::CloudController::Membership::SPACE_MANAGER,
        VCAP::CloudController::Membership::SPACE_AUDITOR,
        VCAP::CloudController::Membership::ORG_MANAGER
      ]

      raise e unless SecurityContext.global_auditor? ||
                     membership.role_applies?(basic_access, process.space.id, process.organization.id)

      [HTTP::OK, Oj.dump({
                           read_sensitive_data: false,
                           read_basic_data: true
                         }, mode: :compat)]
    end

    def get_filtered_dataset_for_enumeration(model, dataset, query_params, opts)
      AppQuery.filtered_dataset_from_query_params(model, dataset, query_params, opts)
    end

    def unprocessable!(message)
      raise CloudController::Errors::ApiError.new_from_details('UnprocessableEntity', message)
    end

    define_messages
    define_routes
  end
end
