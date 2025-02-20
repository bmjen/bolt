# frozen_string_literal: true

require 'sinatra'
require 'addressable/uri'
require 'bolt'
require 'bolt/error'
require 'bolt/target'
require 'bolt_server/file_cache'
require 'bolt/task/puppet_server'
require 'json'
require 'json-schema'

module BoltServer
  class TransportApp < Sinatra::Base
    # This disables Sinatra's error page generation
    set :show_exceptions, false

    # These partial schemas are reused to build multiple request schemas
    PARTIAL_SCHEMAS = %w[target-any target-ssh target-winrm task].freeze

    # These schemas combine shared schemas to describe client requests
    REQUEST_SCHEMAS = %w[
      action-check_node_connections
      action-run_command
      action-run_task
      action-upload_file
      transport-ssh
      transport-winrm
    ].freeze

    def initialize(config)
      @config = config
      @schemas = Hash[REQUEST_SCHEMAS.map do |basename|
        [basename, JSON.parse(File.read(File.join(__dir__, ['schemas', "#{basename}.json"])))]
      end]

      PARTIAL_SCHEMAS.each do |basename|
        schema_content = JSON.parse(File.read(File.join(__dir__, ['schemas', 'partials', "#{basename}.json"])))
        shared_schema = JSON::Schema.new(schema_content, Addressable::URI.parse("partial:#{basename}"))
        JSON::Validator.add_schema(shared_schema)
      end

      @executor = Bolt::Executor.new(0)

      @file_cache = BoltServer::FileCache.new(@config).setup

      super(nil)
    end

    def scrub_stack_trace(result)
      if result.dig(:result, '_error', 'details', 'stack_trace')
        result[:result]['_error']['details'].reject! { |k| k == 'stack_trace' }
      end
      result
    end

    def validate_schema(schema, body)
      schema_error = JSON::Validator.fully_validate(schema, body)
      if schema_error.any?
        Bolt::Error.new("There was an error validating the request body.",
                        'boltserver/schema-error',
                        schema_error)
      end
    end

    # Turns a Bolt::ResultSet object into a status hash that is fit
    # to return to the client in a response.
    #
    # If the `result_set` has more than one result, the status hash
    # will have a `status` value and a list of target `results`.
    # If the `result_set` contains only one item, it will be returned
    # as a single result object. Set `aggregate` to treat it as a set
    # of results with length 1 instead.
    def result_set_to_status_hash(result_set, aggregate: false)
      scrubbed_results = result_set.map do |result|
        scrub_stack_trace(result.status_hash)
      end

      if aggregate || scrubbed_results.length > 1
        # For actions that act on multiple targets, construct a status hash for the aggregate result
        all_succeeded = scrubbed_results.all? { |r| r[:status] == 'success' }
        {
          status: all_succeeded ? 'success' : 'failure',
          result: scrubbed_results
        }
      else
        # If there was only one target, return the first result on its own
        scrubbed_results.first
      end
    end

    def run_task(target, body)
      error = validate_schema(@schemas["action-run_task"], body)
      return [], error unless error.nil?

      task = Bolt::Task::PuppetServer.new(body['task'], @file_cache)
      parameters = body['parameters'] || {}
      [@executor.run_task(target, task, parameters), nil]
    end

    def run_command(target, body)
      error = validate_schema(@schemas["action-run_command"], body)
      return [], error unless error.nil?

      command = body['command']
      [@executor.run_command(target, command), nil]
    end

    def check_node_connections(targets, body)
      error = validate_schema(@schemas["action-check_node_connections"], body)
      return [], error unless error.nil?

      # Puppet Enterprise's orchestrator service uses the
      # check_node_connections endpoint to check whether nodes that should be
      # contacted over SSH or WinRM are responsive. The wait time here is 0
      # because the endpoint is meant to be used for a single check of all
      # nodes; External implementations of wait_until_available (like
      # orchestrator's) should contact the endpoint in their own loop.
      [@executor.wait_until_available(targets, wait_time: 0), nil]
    end

    def upload_file(target, body)
      error = validate_schema(@schemas["action-upload_file"], body)
      return [], error unless error.nil?

      files = body['files']
      destination = body['destination']
      job_id = body['job_id']
      cache_dir = @file_cache.create_cache_dir(job_id.to_s)
      FileUtils.mkdir_p(cache_dir)
      files.each do |file|
        relative_path = file['relative_path']
        uri = file['uri']
        sha256 = file['sha256']
        kind = file['kind']
        path = File.join(cache_dir, relative_path)
        if kind == 'file'
          # The parent should already be created by `directory` entries,
          # but this is to be on the safe side.
          parent = File.dirname(path)
          FileUtils.mkdir_p(parent)
          @file_cache.serial_execute { @file_cache.download_file(path, sha256, uri) }
        elsif kind == 'directory'
          # Create directory in cache so we can move files in.
          FileUtils.mkdir_p(path)
        else
          return [400, Bolt::Error.new("Invalid `kind` of '#{kind}' supplied. Must be `file` or `directory`.",
                                       'boltserver/schema-error').to_json]
        end
      end
      # We need to special case the scenario where only one file was
      # included in the request to download. Otherwise, the call to upload_file
      # will attempt to upload with a directory as a source and potentially a
      # filename as a destination on the host. In that case the end result will
      # be the file downloaded to a directory with the same name as the source
      # filename, rather than directly to the filename set in the destination.
      upload_source = if files.size == 1 && files[0]['kind'] == 'file'
                        File.join(cache_dir, files[0]['relative_path'])
                      else
                        cache_dir
                      end
      [@executor.upload_file(target, upload_source, destination), nil]
    end

    get '/' do
      200
    end

    if ENV['RACK_ENV'] == 'dev'
      get '/admin/gc' do
        GC.start
        200
      end
    end

    get '/admin/gc_stat' do
      [200, GC.stat.to_json]
    end

    get '/500_error' do
      raise 'Unexpected error'
    end

    ACTIONS = %w[
      check_node_connections
      run_command
      run_task
      upload_file
    ].freeze

    def make_ssh_target(target_hash)
      defaults = {
        'host-key-check' => false
      }

      overrides = {
        'load-config' => false
      }

      opts = defaults.merge(target_hash.clone).merge(overrides)

      if opts['private-key-content']
        private_key_content = opts.delete('private-key-content')
        opts['private-key'] = { 'key-data' => private_key_content }
      end

      Bolt::Target.new(target_hash['hostname'], opts)
    end

    post '/ssh/:action' do
      not_found unless ACTIONS.include?(params[:action])

      content_type :json
      body = JSON.parse(request.body.read)

      error = validate_schema(@schemas["transport-ssh"], body)
      return [400, error.to_json] unless error.nil?

      targets = (body['targets'] || [body['target']]).map do |target|
        make_ssh_target(target)
      end

      result_set, error = method(params[:action]).call(targets, body)
      return [400, error.to_json] unless error.nil?

      aggregate = body['target'].nil?
      [200, result_set_to_status_hash(result_set, aggregate: aggregate).to_json]
    end

    def make_winrm_target(target_hash)
      overrides = {
        'protocol' => 'winrm'
      }

      opts = target_hash.clone.merge(overrides)
      Bolt::Target.new(target_hash['hostname'], opts)
    end

    post '/winrm/:action' do
      not_found unless ACTIONS.include?(params[:action])

      content_type :json
      body = JSON.parse(request.body.read)

      error = validate_schema(@schemas["transport-winrm"], body)
      return [400, error.to_json] unless error.nil?

      targets = (body['targets'] || [body['target']]).map do |target|
        make_winrm_target(target)
      end

      result_set, error = method(params[:action]).call(targets, body)
      return [400, error.to_json] if error

      aggregate = body['target'].nil?
      [200, result_set_to_status_hash(result_set, aggregate: aggregate).to_json]
    end

    error 404 do
      err = Bolt::Error.new("Could not find route #{request.path}",
                            'boltserver/not-found')
      [404, err.to_json]
    end

    error 500 do
      e = env['sinatra.error']
      err = Bolt::Error.new("500: Unknown error: #{e.message}",
                            'boltserver/server-error')
      [500, err.to_json]
    end
  end
end
