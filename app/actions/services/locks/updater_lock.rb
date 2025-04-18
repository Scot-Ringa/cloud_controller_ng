require 'actions/services/locks/lock_check'

module VCAP::CloudController
  class UpdaterLock
    include VCAP::CloudController::LockCheck

    attr_reader :service_instance

    def initialize(service_instance, type='update')
      @service_instance = service_instance
      @type = type
      @needs_unlock = false
    end

    def lock!
      ManagedServiceInstance.db.transaction do
        service_instance.lock!

        raise_if_instance_locked(service_instance)

        service_instance.service_bindings.each do |binding|
          raise_if_binding_locked(binding)
        end

        service_instance.save_with_new_operation({}, { type: @type, state: 'in progress' })
        @needs_unlock = true
      end
    end

    def unlock_and_fail!
      ServiceInstanceOperation.db.transaction do
        service_instance.last_operation.update_attributes(
          type: @type,
          state: 'failed'
        )
      end
      @needs_unlock = false
    end

    def synchronous_unlock!
      service_instance.update_last_operation(state: 'succeeded')
      @needs_unlock = false
    end

    def asynchronous_unlock!
      @needs_unlock = false
    end

    def enqueue_unlock!(job)
      Jobs::GenericEnqueuer.shared.enqueue(job)
      @needs_unlock = false
    end

    def needs_unlock?
      @needs_unlock
    end
  end
end
