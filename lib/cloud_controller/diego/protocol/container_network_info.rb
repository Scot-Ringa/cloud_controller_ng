module VCAP::CloudController
  module Diego
    class Protocol
      class ContainerNetworkInfo
        attr_reader :app, :container_purpose

        APP = 'app'.freeze
        STAGING = 'staging'.freeze
        TASK = 'task'.freeze

        def initialize(app, container_purpose)
          @app = app
          @container_purpose = container_purpose
        end

        def to_h
          {
            'properties' => {
              'policy_group_id' => app.guid,
              'app_id' => app.guid,
              'space_id' => app.space.guid,
              'org_id' => app.organization.guid,
              'ports' => app.processes.map { |p| Protocol::OpenProcessPorts.new(p).to_a }.flatten.sort.join(','),
              'container_purpose' => container_purpose,
            },
          }
        end

        def to_bbs_network
          network = ::Diego::Bbs::Models::Network.new(properties: [])

          to_h['properties'].each do |key, value|
            network.properties << ::Diego::Bbs::Models::Network::PropertiesEntry.new(
              key:   key,
              value: value,
            )
          end

          network
        end
      end
    end
  end
end
