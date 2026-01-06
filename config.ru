# Monkey-patch to disable HostAuthorization BEFORE loading app
require "rack/protection"

module Rack
  module Protection
    class HostAuthorization
      def call(env)
        @app.call(env)
      end
    end
  end
end

require_relative "./app"

run Sinatra::Application
