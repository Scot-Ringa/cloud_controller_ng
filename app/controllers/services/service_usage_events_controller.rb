module VCAP::CloudController
  class ServiceUsageEventsController < RestController::ModelController
    query_parameters :service_instance_type, :service_guid

    preserve_query_parameters :after_guid

    get '/v2/service_usage_events', :enumerate

    get path_guid, :read

    post '/v2/service_usage_events/destructively_purge_all_and_reseed_existing_instances', :reset
    def reset
      validate_access(:reset, model)

      repository = Repositories::ServiceUsageEventRepository.new
      repository.purge_and_reseed_service_instances!

      [HTTP::NO_CONTENT, nil]
    end

    def self.not_found_exception_name(_model_class)
      'EventNotFound'
    end

    private

    def get_filtered_dataset_for_enumeration(model, dataset, query_params, opts)
      after_guid = params['after_guid']
      if after_guid
        repository = Repositories::ServiceUsageEventRepository.new
        previous_event = repository.find(after_guid)
        raise CloudController::Errors::ApiError.new_from_details('BadQueryParameter', after_guid) unless previous_event

        dataset = dataset.filter { id > previous_event.id }
      end
      super
    end
  end
end
