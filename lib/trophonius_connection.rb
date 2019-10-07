require 'base64'
require 'typhoeus'

module Trophonius
  module Trophonius::Connection
    ##
    # Creates a new connection to FileMaker
    #
    # @return [String] the *token* used to connect with the FileMaker data api

    def self.connect
      @token = setup_connection
      @last_connection = Time.now
      @token
    end

    ##
    # Creates and runs a HTTP request to create a new data api connection
    # This method throws an error when the request returns with a HTTP error or a FileMaker error
    # @return [String] the *token* used to connect with the FileMaker data api if successful

    def self.setup_connection
      @token = ''
      ssl_verifyhost = Trophonius.config.local_network ? 0 : 2
      ssl_verifypeer = !Trophonius.config.local_network
      url = URI("http#{Trophonius.config.ssl == true ? 's' : ''}://#{Trophonius.config.host}/fmi/data/v1/databases/#{Trophonius.config.database}/sessions")
      request = Typhoeus::Request.new(
        url,
        method: :post,
        body: Trophonius.config.external_name.empty? ? {} : { fmDataSource: [ { database: Trophonius.config.external_name , username: Trophonius.config.external_username, password: Trophonius.config.external_password } ] }.to_json,
        params: {},
        ssl_verifyhost: ssl_verifyhost,
        ssl_verifypeer: ssl_verifypeer,
        headers: { 'Content-Type' => 'application/json', Authorization: "Basic #{Base64.strict_encode64("#{Trophonius.config.username}:#{Trophonius.config.password}")}" }
      )
      temp = request.run

      begin
        parsed = JSON.parse(temp.response_body)
        if parsed['messages'][0]['code'] != '0'
          Error.throw_error(response['messages'][0]['code'])
        end
        return parsed['response']['token']
      rescue Exception
        Error.throw_error('1631')
      end
    end

    ##
    # Returns the last received token
    # @return [String] the last valid *token* used to connect with the FileMaker data api
    def self.token
      @token
    end

    ##
    # Returns the receive time of the last received token
    # @return [Time] Returns the receive time of the last received token
    def self.last_connection
      @last_connection
    end

    ##
    # Tests whether the FileMaker token is still valid
    # @return [Boolean] True if the token is valid False if invalid
    def self.test_connection
      url = URI("http#{Trophonius.config.ssl == true ? 's' : ''}://#{Trophonius.config.host}/fmi/data/v1/databases/#{Trophonius.config.database}/layouts/#{Trophonius.config.layout_name}/records?_limit=1")
      begin
        request = Typhoeus::Request.new(
          url,
          method: :get,
          body: {},
          params: {},
          headers: { 'Content-Type' => 'application/json', Authorization: "Bearer #{@token}" }
        )
        temp = request.run
        JSON.parse(temp.response_body)['messages'][0]['code'] == '0'
      rescue StandardError
        return false
      end
    end

    ##
    # Returns whether the current connection is still valid
    # @return [Boolean] True if the connection is valid False if invalid
    def self.valid_connection?
      @last_connection.nil? ? false : (((Time.now - last_connection) / 60).round <= 15 || test_connection)
    end
  end
end
