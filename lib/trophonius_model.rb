require 'json'
require 'trophonius_config'
require 'trophonius_record'
require 'trophonius_recordset'
require 'trophonius_query'
require 'trophonius_error'

module Trophonius
  # This class will retrieve the records from the FileMaker database and build a RecordSet filled with Record objects. One Record object represents a record in FileMaker.
  class Trophonius::Model
    attr_reader :configuration
    attr_accessor :current_query

    def initialize(config:)
      @configuration = config
      @offset = ''
      @limit = ''
    end

    ##
    # Sets up the configuration for the model.
    #
    # @param [Hash] configuration: the hash containing the config to setup the model correctly.
    #   configuration = {layout_name: "theFileMakerLayoutForThisModel", non_modifiable_fields: ["an", "array", "containing", "calculation_fields", "etc."]}
    def self.config(configuration)
      @configuration ||= Configuration.new
      @configuration.layout_name = configuration[:layout_name]
      @configuration.non_modifiable_fields = configuration[:non_modifiable_fields]
      @configuration.all_fields = {}
      @configuration.translations = {}
      @configuration.has_many_relations = {}
      @configuration.belongs_to_relations = {}
      @offset = ''
      @limit = ''
    end

    ##
    # Add a belongs to relationship.
    #
    # @param [Symbol] model_name: the name of the model to build a relation with
    # @param [String] primary_key: the name of the field containing the primary to build the relation over
    # @param [String] foreign_key: the name of the field containing the primary to build the relation over
    def self.belongs_to(model_name, primary_key:, foreign_key:)
      @configuration.belongs_to_relations.merge!({ model_name => { primary_key: primary_key, foreign_key: foreign_key } })
    end

    ##
    # Add a has many relationship.
    #
    # @param [Symbol] model_name: the name of the model to build a relation with
    # @param [String] primary_key: the name of the field containing the primary to build the relation over
    # @param [String] foreign_key: the name of the field containing the primary to build the relation over
    def self.has_many(model_name, primary_key:, foreign_key:)
      @configuration.has_many_relations.merge!({ model_name => { primary_key: primary_key, foreign_key: foreign_key } })
    end

    ##
    # Limits the found record set.
    #
    # @param [Integer] page: number of current page
    # @param [Integer] limit: number of records retreived
    #
    # @return [Trophonius::Model] Self
    def self.paginate(page, limit)
      @offset = ((page * limit - limit) + 1).to_s
      @limit = limit.to_s
      self
    end

    ##
    # Returns the FileMaker layout this Model corresponds to
    #
    # @return [String] layout name of the model
    def self.layout_name
      @configuration.layout_name
    end

    ##
    # Returns the Hash containing the related parent models
    #
    # @return [Hash] child models
    def self.has_many_relations
      @configuration.has_many_relations
    end

    ##
    # Returns the Hash containing the related parent models
    #
    # @return [Hash] parent models
    def self.belongs_to_relations
      @configuration.belongs_to_relations
    end

    ##
    # Returns the fields that FileMaker won't allow us to modify
    #
    # @return [[Array]] fields that FileMaker won't allow us to modify
    def self.non_modifiable_fields
      @configuration.non_modifiable_fields
    end

    ##
    # Returns the translations of the fields
    #
    # @return [Hash] translations of the fields Rails -> FileMaker
    def self.translations
      @configuration.translations
    end

    ##
    # creates Rails -> FileMaker field translations by requesting the first record
    #
    # @return [Hash] translations of the fields Rails -> FileMaker
    def self.create_translations
      if Trophonius.config.fm_18
        field_names = Trophonius::Request.get_layout_field_names(layout_name)
        field_names.each do |field|
          @configuration.translations.merge!(
            { "#{ActiveSupport::Inflector.parameterize(ActiveSupport::Inflector.underscore(field.to_s), separator: '_').downcase}" => "#{field}" }
          )
        end
      else
        self.first
      end
      @configuration.translations
    end

    def self.method_missing(method, *args, &block)
      new_instance = Trophonius::Model.new(config: @configuration)
      new_instance.current_query = Trophonius::Query.new(trophonius_model: self, limit: @limit, offset: @offset)
      args << new_instance
      new_instance.current_query.send(method, args) if new_instance.current_query.respond_to?(method)
    end

    def method_missing(method, *args, &block)
      if @current_query.respond_to?(method)
        args << self
        @current_query.send(method, args)
      elsif @current_query.response.respond_to?(method)
        ret_val = @current_query.run_query(method, *args, &block)
        @limit = ''
        @offset = ''
        return ret_val
      end
    end

    ##
    # Finds all records in FileMaker corresponding to the requested query
    # @param [Hash] fieldData: the data to find
    #
    # @return [Trophonius::Model] new instance of the model
    def self.where(fieldData)
      new_instance = Trophonius::Model.new(config: @configuration)
      new_instance.current_query = Trophonius::Query.new(trophonius_model: self, limit: @limit, offset: @offset)
      new_instance.current_query.build_query[0].merge!(fieldData)
      new_instance
    end

    ##
    # Finds all records in FileMaker corresponding to the requested query
    # This method is created to enable where chaining
    #
    # @param [Hash] fieldData: the data to find
    #
    # @return [Trophonius::Model] new instance of the model
    def where(fieldData)
      @current_query.build_query[0].merge!(fieldData)
      self
    end

    ##
    # Creates and saves a record in FileMaker
    #
    # @param [Hash] fieldData: the fields to fill with the data
    #
    # @return [Record] the created record
    #   Model.create(fieldOne: "Data")
    def self.create(fieldData, portalData: {})
      url =
        URI(
          URI.escape(
            "http#{Trophonius.config.ssl == true ? 's' : ''}://#{Trophonius.config.host}/fmi/data/v1/databases/#{
              Trophonius.config.database
            }/layouts/#{layout_name}/records"
          )
        )
      new_field_data = {}
      create_translations if @configuration.translations.keys.empty?
      fieldData.keys.each do |k|
        if @configuration.translations.keys.include?(k.to_s)
          new_field_data.merge!({ "#{@configuration.translations[k.to_s]}" => fieldData[k] })
        else
          new_field_data.merge!({ "#{k}" => fieldData[k] })
        end
      end

      new_portal_data = {}
      portalData.each do |portal_name, portal_values|
        new_portal_data.merge!(
          portal_name =>
            portal_values.map do |record|
              record.inject({}) do |new_hash, (key, value)|
                new_hash["#{portal_name}::#{key}"] = value
                new_hash
              end
            end
        )
      end

      body =
        if new_portal_data != {}
          "{\"fieldData\": #{new_field_data.to_json}, \"portalData\": #{new_portal_data.to_json}}"
        else
          "{\"fieldData\": #{new_field_data.to_json} }"
        end
      response = Request.make_request(url, "Bearer #{Request.get_token}", 'post', body)
      if response['messages'][0]['code'] != '0'
        if response['messages'][0]['code'] == '102'
          results = Request.retrieve_first(layout_name)
          if results['messages'][0]['code'] != '0'
            Error.throw_error('102')
          else
            r_results = results['response']['data']
            ret_val = r_results.empty? ? Error.throw_error('102') : r_results[0]['fieldData']
            Error.throw_error('102', (new_field_data.keys.map(&:downcase) - ret_val.keys.map(&:downcase)).flatten.join(', '), layout_name)
          end
        end
        Error.throw_error(response['messages'][0]['code'])
      else
        url =
          URI(
            URI.escape(
              "http#{Trophonius.config.ssl == true ? 's' : ''}://#{Trophonius.config.host}/fmi/data/v1/databases/#{
                Trophonius.config.database
              }/layouts/#{layout_name}/records/#{response['response']['recordId']}"
            )
          )
        ret_val = build_result(Request.make_request(url, "Bearer #{Request.get_token}", 'get', '{}')['response']['data'][0])
        ret_val.send(:define_singleton_method, 'result_count') { 1 }
        return ret_val
      end
    end

    ##
    # Finds and returns the first Record containing fitting the find request
    #
    # @param [Hash] fieldData: the data to find
    #
    # @return [Record] a Record object that correspond to FileMaker record fitting the find request
    #   Model.find_by(fieldOne: "Data")
    def self.find_by(fieldData)
      url =
        URI(
          URI.escape(
            "http#{Trophonius.config.ssl == true ? 's' : ''}://#{Trophonius.config.host}/fmi/data/v1/databases/#{
              Trophonius.config.database
            }/layouts/#{self.layout_name}/_find?_limit=1"
          )
        )
      new_field_data = {}
      create_translations if @configuration.translations.keys.empty?
      fieldData.keys.each do |k|
        if @configuration.translations.keys.include?(k.to_s)
          new_field_data.merge!({ "#{@configuration.translations[k.to_s]}" => fieldData[k] })
        else
          new_field_data.merge!({ "#{k}" => fieldData[k] })
        end
      end
      body = { query: [new_field_data], limit: '100000' }.to_json
      response = Request.make_request(url, "Bearer #{Request.get_token}", 'post', body)

      if response['messages'][0]['code'] != '0'
        if response['messages'][0]['code'] == '101' || response['messages'][0]['code'] == '401'
          return RecordSet.new(self.layout_name, self.non_modifiable_fields)
        end
        Error.throw_error(response['messages'][0]['code'])
      else
        r_results = response['response']['data']
        ret_val = RecordSet.new(self.layout_name, self.non_modifiable_fields)
        r_results.each do |r|
          hash = build_result(r)
          ret_val << hash
        end
        return ret_val.first
      end
    end

    ##
    # Finds and returns a Record corresponding to the record_id
    #
    # @param [Integer] record_id: the record id to retrieve from FileMaker
    #
    # @return [Record] the record
    def self.find(record_id)
      url =
        URI(
          URI.escape(
            "http#{Trophonius.config.ssl == true ? 's' : ''}://#{Trophonius.config.host}/fmi/data/v1/databases/#{
              Trophonius.config.database
            }/layouts/#{layout_name}/records/#{record_id}"
          )
        )
      response = Request.make_request(url, "Bearer #{Request.get_token}", 'get', '{}')
      if response['messages'][0]['code'] != '0'
        Error.throw_error(response['messages'][0]['code'], record_id)
      else
        ret_val = build_result(response['response']['data'][0])
        ret_val.send(:define_singleton_method, 'result_count') { 1 }
        return ret_val
      end
    end

    ##
    # Deletes a record from FileMaker
    #
    # @param [Integer] record_id: the record id to retrieve from FileMaker
    #
    # @return [Boolean] True if the delete was successful
    def self.delete(record_id)
      url =
        URI(
          URI.escape(
            "http#{Trophonius.config.ssl == true ? 's' : ''}://#{Trophonius.config.host}/fmi/data/v1/databases/#{
              Trophonius.config.database
            }/layouts/#{layout_name}/records/#{record_id}"
          )
        )
      response = Request.make_request(url, "Bearer #{Request.get_token}", 'delete', '{}')
      if response['messages'][0]['code'] != '0'
        Error.throw_error(response['messages'][0]['code'])
      else
        return true
      end
    end

    ##
    # Edits a record in FileMaker
    #
    # @param [Integer] record_id: the record id to edit in FileMaker
    #
    # @param [Hash] fieldData: A hash containing the fields to edit and the new data to fill them with
    #
    # @return [Boolean] True if the delete was successful
    def self.edit(record_id, fieldData)
      url =
        URI(
          URI.escape(
            "http#{Trophonius.config.ssl == true ? 's' : ''}://#{Trophonius.config.host}/fmi/data/v1/databases/#{
              Trophonius.config.database
            }/layouts/#{layout_name}/records/#{record_id}"
          )
        )
      new_field_data = {}
      create_translations if @configuration.translations.keys.empty?
      fieldData.keys.each do |k|
        if @configuration.translations.keys.include?(k.to_s)
          new_field_data.merge!({ "#{@configuration.translations[k.to_s]}" => fieldData[k] })
        else
          new_field_data.merge!({ "#{k}" => fieldData[k] })
        end
      end
      body = "{\"fieldData\": #{new_field_data.to_json}}"
      response = Request.make_request(url, "Bearer #{Request.get_token}", 'patch', body)
      response['messages'][0]['code'] != '0' ? Error.throw_error(response['messages'][0]['code']) : true
    end

    ##
    # Builds the resulting Record
    #
    # @param [JSON] result: the HTTP result from FileMaker
    #
    # @return [Record] A Record with singleton_methods for the fields where possible
    def self.build_result(result)
      hash = Trophonius::Record.new
      hash.record_id = result['recordId']
      hash.layout_name = layout_name
      hash.model_name = name

      result['fieldData'].keys.each do |key|
        # unless key[/\s/] || key[/\W/]
        @configuration.translations.merge!(
          { "#{ActiveSupport::Inflector.parameterize(ActiveSupport::Inflector.underscore(key.to_s), separator: '_').downcase}" => "#{key}" }
        )
        hash.send(:define_singleton_method, ActiveSupport::Inflector.parameterize(ActiveSupport::Inflector.underscore(key.to_s), separator: '_')) do
          hash[key]
        end
        unless non_modifiable_fields&.include?(key)
          @configuration.all_fields.merge!(
            ActiveSupport::Inflector.parameterize(ActiveSupport::Inflector.underscore(key.to_s), separator: '_').downcase =>
              ActiveSupport::Inflector.parameterize(ActiveSupport::Inflector.underscore(key.to_s), separator: '_')
          )
          hash.send(
            :define_singleton_method,
            "#{ActiveSupport::Inflector.parameterize(ActiveSupport::Inflector.underscore(key.to_s), separator: '_')}="
          ) do |new_val|
            hash[key] = new_val
            hash.modifiable_fields[key] = new_val
            hash.modified_fields[key] = new_val
          end
        end
        # end
        hash.merge!({ key => result['fieldData'][key] })
        hash.modifiable_fields.merge!({ key => result['fieldData'][key] }) unless non_modifiable_fields&.include?(key)
      end
      result['portalData'].keys.each do |key|
        unless key[/\s/] || key[/\W/]
          hash.send(:define_singleton_method, ActiveSupport::Inflector.parameterize(ActiveSupport::Inflector.underscore(key.to_s), separator: '_')) do
            hash[key]
          end
        end
        result['portalData'][key].each_with_index do |inner_hash|
          inner_hash.keys.each do |inner_key|
            inner_method =
              ActiveSupport::Inflector.parameterize(ActiveSupport::Inflector.underscore(inner_key.gsub(/\w+::/, '').to_s), separator: '_')
            unless inner_method[/\s/] || inner_method[/\W/]
              inner_hash.send(:define_singleton_method, inner_method.to_s) { inner_hash[inner_key] }
              inner_hash.send(:define_singleton_method, 'record_id') { inner_hash['recordId'] }
            end
          end
        end
        hash.merge!({ key => result['portalData'][key] })
      end
      return hash
    end

    ##
    # Retrieve the first record from FileMaker from the context of the Model.
    #
    # @return [Record]: a Record corresponding to the FileMaker record.
    def self.first
      results = Request.retrieve_first(layout_name)
      if results['messages'][0]['code'] != '0'
        Error.throw_error(results['messages'][0]['code'])
      else
        r_results = results['response']['data']
        ret_val = r_results.empty? ? Trophonius::Record.new : build_result(r_results[0])
        ret_val.send(:define_singleton_method, 'result_count') { r_results.empty? ? 0 : 1 }
        return ret_val
      end
    end

    ##
    # Runs a FileMaker script from the context of the Model.
    #
    # @param [String] script: the FileMaker script to run
    #
    # @param [String] scriptparameter: the parameter required by the FileMaker script
    #
    # @return [String]: string representing the script result returned by FileMaker
    def self.run_script(script: '', scriptparameter: '')
      result = Request.run_script(script, scriptparameter, layout_name)
      if result['messages'][0]['code'] != '0'
        Error.throw_error(result['messages'][0]['code'])
      elsif result['response']['scriptResult'] == '403'
        Error.throw_error(403)
      else
        ret_val = result['response']['scriptResult']
        return ret_val
      end
    end

    ##
    # Retrieve the first 10000000 records from FileMaker from the context of the Model.
    #
    # @param [Hash] sort: a hash containing the fields to sort by and the direction to sort in (optional)
    #
    # @return [RecordSet]: a RecordSet containing all the Record objects that correspond to the FileMaker records.
    def self.all(sort: {})
      results = Request.retrieve_all(layout_name, sort)
      count = results['response']['scriptResult'].to_i
      unless @limit.empty? || @offset.empty?
        url =
          URI(
            URI.escape(
              "http#{Trophonius.config.ssl == true ? 's' : ''}://#{Trophonius.config.host}/fmi/data/v1/databases/#{
                Trophonius.config.database
              }/layouts/#{layout_name}/records?_offset=#{@offset}&_limit=#{@limit}"
            )
          )
      else
        url =
          URI(
            URI.escape(
              "http#{Trophonius.config.ssl == true ? 's' : ''}://#{Trophonius.config.host}/fmi/data/v1/databases/#{
                Trophonius.config.database
              }/layouts/#{layout_name}/records?_limit=#{count == 0 ? 1_000_000 : count}"
            )
          )
      end
      @limit = ''
      @offset = ''
      results = Request.make_request(url, "Bearer #{Request.get_token}", 'get', '{}')
      if results['messages'][0]['code'] != '0'
        Error.throw_error(results['messages'][0]['code'])
      else
        r_results = results['response']['data']
        ret_val = RecordSet.new(self.layout_name, self.non_modifiable_fields)
        r_results.each do |r|
          hash = build_result(r)
          ret_val << hash
        end
        ret_val.result_count = count
        return ret_val
      end
    end
  end
end
