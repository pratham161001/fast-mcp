# frozen_string_literal: true

RSpec.describe FastMcp::Server do
  let(:server) { described_class.new(name: 'test-server', version: '1.0.0', logger: Logger.new(nil)) }

  describe '#initialize' do
    it 'creates a server with the given name and version' do
      expect(server.name).to eq('test-server')
      expect(server.version).to eq('1.0.0')
      expect(server.tools).to be_empty
    end
  end

  describe '#register_tool' do
    it 'registers a tool with the server' do
      test_tool_class = Class.new(FastMcp::Tool) do
        def self.name
          'test-tool'
        end

        def self.description
          'A test tool'
        end

        def call(**_args)
          'Hello, World!'
        end
      end

      server.register_tool(test_tool_class)

      expect(server.tools['test-tool']).to eq(test_tool_class)
    end
  end

  describe '#handle_request' do
    let(:test_tool_class) do
      Class.new(FastMcp::Tool) do
        def self.name
          'test-tool'
        end

        def self.description
          'A test tool'
        end

        arguments do
          required(:name).filled(:string).description('User name')
        end

        def call(name:)
          "Hello, #{name}!"
        end
      end
    end

    let(:profile_tool_class) do
      Class.new(FastMcp::Tool) do
        def self.name
          'profile-tool'
        end

        def self.description
          'A tool for handling user profiles'
        end

        arguments do
          required(:user).hash do
            required(:first_name).filled(:string).description('First name of the user')
            required(:last_name).filled(:string).description('Last name of the user')
          end
        end

        def call(user:)
          "#{user[:first_name]} #{user[:last_name]}"
        end
      end
    end

    before do
      # Register the test tools
      server.register_tool(test_tool_class)
      server.register_tool(profile_tool_class)

      # Stub the send_response method
      allow(server).to receive(:send_response)
    end

    context 'with a ping request' do
      it 'responds with an empty result' do
        request = { jsonrpc: '2.0', method: 'ping', id: 1 }.to_json

        expect(server).to receive(:send_result).with({}, 1)
        server.handle_request(request)
      end
    end

    context 'with a ping response' do
      it 'responds with an empty result' do
        request = { result: {}, id: 1, jsonrpc: '2.0' }.to_json
        expect(server).not_to receive(:send_result)

        response = server.handle_request(request)
        expect(response).to be_nil
      end
    end

    context 'with a notifications/initialized request' do
      it 'responds with nil' do
        request = { jsonrpc: '2.0', method: 'notifications/initialized' }.to_json

        response = server.handle_request(request)
        expect(response).to be_nil
      end
    end

    context 'with an initialize request' do
      it 'responds with the server info' do
        request = { jsonrpc: '2.0', method: 'initialize', id: 1 }.to_json

        expect(server).to receive(:send_result).with({
                                                       protocolVersion: FastMcp::Server::PROTOCOL_VERSION,
                                                       capabilities: server.capabilities,
                                                       serverInfo: {
                                                         name: server.name,
                                                         version: server.version
                                                       }
                                                     }, 1)
        server.handle_request(request)
      end
    end

    context 'with a tools/list request' do
      it 'responds with a list of tools' do
        request = { jsonrpc: '2.0', method: 'tools/list', id: 1 }.to_json

        expect(server).to receive(:send_result) do |result, id|
          expect(id).to eq(1)
          expect(result[:tools]).to be_an(Array)
          expect(result[:tools].length).to eq(2)

          # Test the simple tool
          test_tool = result[:tools].find { |t| t[:name] == 'test-tool' }
          expect(test_tool[:description]).to eq('A test tool')
          expect(test_tool[:inputSchema]).to be_a(Hash)
          expect(test_tool[:inputSchema][:properties][:name][:description]).to eq('User name')

          # Test the tool with nested properties
          profile_tool = result[:tools].find { |t| t[:name] == 'profile-tool' }
          expect(profile_tool[:description]).to eq('A tool for handling user profiles')
          expect(profile_tool[:inputSchema][:properties][:user][:type]).to eq('object')
          # We no longer expect descriptions on nested fields since they aren't being passed through
          expect(profile_tool[:inputSchema][:properties][:user][:properties]).to have_key(:first_name)
          expect(profile_tool[:inputSchema][:properties][:user][:properties]).to have_key(:last_name)
        end

        server.handle_request(request)
      end
      
      context 'with tool annotations' do
        let(:annotated_tool_class) do
          Class.new(FastMcp::Tool) do
            def self.name
              'annotated-tool'
            end

            def self.description
              'A tool with annotations'
            end
            
            annotations(
              title: 'Web Search Tool',
              read_only_hint: true,
              open_world_hint: true
            )

            def call(**_args)
              'Searching...'
            end
          end
        end
        
        before do
          server.register_tool(annotated_tool_class)
        end
        
        it 'includes annotations in the tools list' do
          request = { jsonrpc: '2.0', method: 'tools/list', id: 1 }.to_json

          expect(server).to receive(:send_result) do |result, id|
            expect(id).to eq(1)
            
            annotated_tool = result[:tools].find { |t| t[:name] == 'annotated-tool' }
            expect(annotated_tool[:annotations]).to eq({
              title: 'Web Search Tool',
              readOnlyHint: true,
              openWorldHint: true
            })
          end

          server.handle_request(request)
        end
      end
      
      context 'with tool without annotations' do
        it 'does not include annotations field' do
          request = { jsonrpc: '2.0', method: 'tools/list', id: 1 }.to_json

          expect(server).to receive(:send_result) do |result, id|
            expect(id).to eq(1)
            
            test_tool = result[:tools].find { |t| t[:name] == 'test-tool' }
            expect(test_tool).not_to have_key(:annotations)
          end

          server.handle_request(request)
        end
      end
    end

    context 'with a tools/call request' do
      it 'calls the specified tool and returns the result' do
        request = {
          jsonrpc: '2.0',
          method: 'tools/call',
          params: {
            name: 'test-tool',
            arguments: { name: 'World' }
          },
          id: 1
        }.to_json

        expect(server).to receive(:send_result).with(
          { content: [{ text: 'Hello, World!', type: 'text' }], isError: false },
          1,
          metadata: {}
        )
        server.handle_request(request)
      end

      it 'calls a tool with nested properties' do
        request = {
          jsonrpc: '2.0',
          method: 'tools/call',
          params: {
            name: 'profile-tool',
            arguments: {
              user: {
                first_name: 'John',
                last_name: 'Doe'
              }
            }
          },
          id: 1
        }.to_json

        expect(server).to receive(:send_result).with(
          { content: [{ text: 'John Doe', type: 'text' }], isError: false },
          1,
          metadata: {}
        )
        server.handle_request(request)
      end

      it "returns an error if the tool doesn't exist" do
        request = {
          jsonrpc: '2.0',
          method: 'tools/call',
          params: {
            name: 'non-existent-tool',
            arguments: {}
          },
          id: 1
        }.to_json

        expect(server).to receive(:send_error).with(-32_602, 'Tool not found: non-existent-tool', 1)
        server.handle_request(request)
      end

      it 'returns an error if the tool name is missing' do
        request = {
          jsonrpc: '2.0',
          method: 'tools/call',
          params: {
            arguments: {}
          },
          id: 1
        }.to_json

        expect(server).to receive(:send_error).with(-32_602, 'Invalid params: missing tool name', 1)
        server.handle_request(request)
      end
    end

    context 'with an invalid request' do
      it 'returns an error for an unknown method' do
        request = { jsonrpc: '2.0', method: 'unknown', id: 1 }.to_json

        expect(server).to receive(:send_error).with(-32_601, 'Method not found: unknown', 1)
        server.handle_request(request)
      end

      it 'returns an error for an invalid JSON-RPC request' do
        request = { id: 1 }.to_json

        expect(server).to receive(:send_error).with(-32_600, 'Invalid Request', 1)
        server.handle_request(request)
      end

      it 'returns an error for an invalid JSON request' do
        request = 'invalid json'

        expect(server).to receive(:send_error).with(-32_600, 'Invalid Request', nil)
        server.handle_request(request)
      end
    end

    describe 'metadata handling' do
      let(:metadata_helper) do
        Class.new { include FastMcp::Metadata }.new
      end

      it 'validates metadata keys for reserved prefixes' do
        expect { metadata_helper.validate_meta_field({ 'mcp:reserved' => 'value' }) }.to raise_error(
          FastMcp::Metadata::ReservedMetadataError
        )
      end

      it 'sanitizes metadata correctly' do
        metadata = {
          'valid_key' => 'value',
          'mcp:reserved' => 'should_be_removed',
          'mcp-reserved' => 'should_be_removed',
          '' => 'empty_key'
        }
        
        sanitized = metadata_helper.sanitize_meta_field(metadata)
        expect(sanitized).to eq({ 'valid_key' => 'value' })
      end

      it 'formats metadata for JSON serialization' do
        # Test with valid metadata
        metadata = { 'app_version' => '1.0.0', 'request_id' => 'abc123' }
        formatted = metadata_helper.format_meta_field(metadata)
        expect(formatted).to eq(metadata)
        
        # Test with metadata that gets filtered out
        invalid_metadata = { 'mcp:reserved' => 'value', 'mcp-reserved' => 'value' }
        formatted = metadata_helper.format_meta_field(invalid_metadata)
        expect(formatted).to be_nil
      end

      it 'merges metadata from multiple sources' do
        meta1 = { 'key1' => 'value1', 'common' => 'meta1' }
        meta2 = { 'key2' => 'value2', 'common' => 'meta2' }
        
        merged = metadata_helper.merge_meta_fields(meta1, meta2)
        expect(merged).to eq({
          'key1' => 'value1',
          'key2' => 'value2',
          'common' => 'meta2'  # Later sources take precedence
        })
      end
    end
  end
end
