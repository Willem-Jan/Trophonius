module Trophonius
  class Trophonius::Configuration
    include ActiveSupport::Configurable

    config_accessor(:host) { "127.0.0.1" }
    config_accessor(:port) { 0 }
    config_accessor(:database) { "" }
    config_accessor(:username) { "Admin" }
    config_accessor(:password) { "" }
    config_accessor(:ssl) { true }
    config_accessor(:count_result_script) { "" }
    config_accessor(:layout_name) { "" }
    config_accessor(:non_modifiable_fields) { [] }
  end
end
