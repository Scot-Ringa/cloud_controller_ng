require 'spec_helper'

## NOTICE: Prefer request specs over controller specs as per ADR #0003 ##

module VCAP::CloudController
  RSpec.describe VCAP::CloudController::InfoController do
    describe 'GET /v2/info' do
      it "returns a 'user' entry when authenticated" do
        set_current_user(User.make)

        get '/v2/info'
        hash = Oj.load(last_response.body)
        expect(hash).to have_key('user')
      end

      it "excludes the 'user' entry when not authenticated" do
        get '/v2/info'
        hash = Oj.load(last_response.body)
        expect(hash).not_to have_key('user')
      end

      it 'includes data from the config' do
        get '/v2/info'
        hash = Oj.load(last_response.body)
        expect(hash['name']).to eq(TestConfig.config[:info][:name])
        expect(hash['build']).to eq(TestConfig.config[:info][:build])
        expect(hash['support']).to eq(TestConfig.config[:info][:support_address])
        expect(hash['version']).to eq(TestConfig.config[:info][:version])
        expect(hash['description']).to eq(TestConfig.config[:info][:description])
        expect(hash['authorization_endpoint']).to eq(TestConfig.config[:login][:url])
        expect(hash['token_endpoint']).to eq(TestConfig.config[:uaa][:url])
        expect(hash['app_ssh_endpoint']).to eq(TestConfig.config[:info][:app_ssh_endpoint])
        expect(hash['app_ssh_host_key_fingerprint']).to eq(TestConfig.config[:info][:app_ssh_host_key_fingerprint])
        expect(hash['app_ssh_oauth_client']).to eq(TestConfig.config[:info][:app_ssh_oauth_client])
        expect(hash['api_version']).to eq(VCAP::CloudController::Constants::API_VERSION)
        expect(hash['osbapi_version']).to eq(VCAP::CloudController::Constants::OSBAPI_VERSION)
      end

      it 'includes the routing api endpoint when configured' do
        TestConfig.override(routing_api: { url: 'some_routing_api' })
        get '/v2/info'
        hash = Oj.load(last_response.body)
        expect(hash['routing_endpoint']).to eq('some_routing_api')
      end

      it 'includes the doppler_logging_endpoint' do
        TestConfig.override(doppler: { url: 'doppler_url' })
        get '/v2/info'
        hash = Oj.load(last_response.body)
        expect(hash['doppler_logging_endpoint']).to eq('doppler_url')
      end

      it 'includes cli version info when confgired' do
        TestConfig.override(info: {
                              min_cli_version: 'min_cli_version',
                              min_recommended_cli_version: 'min_recommended_cli_version'
                            })
        get '/v2/info'
        hash = Oj.load(last_response.body)
        expect(hash['min_cli_version']).to eq('min_cli_version')
        expect(hash['min_recommended_cli_version']).to eq('min_recommended_cli_version')
      end

      it 'returns limited info when cc.temporary_enable_v2 is disabled' do
        TestConfig.override(temporary_enable_v2: false)

        get '/v2/info'
        hash = Oj.load(last_response.body)
        expect(hash['name']).to eq(TestConfig.config[:info][:name])
        expect(hash['build']).to eq(TestConfig.config[:info][:build])
        expect(hash['support']).to eq('CF API v2 is disabled')
        expect(hash['version']).to eq(TestConfig.config[:info][:version])
        expect(hash['description']).to eq(TestConfig.config[:info][:description])
        expect(hash['authorization_endpoint']).to eq(TestConfig.config[:login][:url])
        expect(hash['token_endpoint']).to eq(TestConfig.config[:uaa][:url])
        expect(hash['app_ssh_endpoint']).to eq(TestConfig.config[:info][:app_ssh_endpoint])
        expect(hash['app_ssh_host_key_fingerprint']).to eq(TestConfig.config[:info][:app_ssh_host_key_fingerprint])
        expect(hash['app_ssh_oauth_client']).to eq(TestConfig.config[:info][:app_ssh_oauth_client])
        expect(hash['api_version']).to eq('')
        expect(hash['osbapi_version']).to eq(VCAP::CloudController::Constants::OSBAPI_VERSION)
      end

      describe 'custom fields' do
        context 'without custom fields in config' do
          before { TestConfig.override(info: {}) }

          it 'does not have custom fields in the hash' do
            get '/v2/info'
            hash = Oj.load(last_response.body)
            expect(hash).not_to have_key('custom')
          end
        end

        context 'with custom fields in config' do
          before { TestConfig.override(info: { custom: { foo: 'bar', baz: 'foobar' } }) }

          it 'contains the custom fields' do
            get '/v2/info'

            hash = Oj.load(last_response.body)
            expect(hash).to have_key('custom')
            expect(hash['custom']).to eq({ 'foo' => 'bar', 'baz' => 'foobar' })
          end
        end
      end
    end
  end
end
