require "rack/protection"
require "stringio"

# Custom middleware to capture raw body for Slack signature verification
class RawBodyCapture
  def initialize(app)
    @app = app
  end

  def call(env)
    if env["REQUEST_METHOD"] == "POST" && env["PATH_INFO"] == "/slack/deploy"
      # Read and store the raw body
      body = env["rack.input"].read
      env["rack.input.raw"] = body
      puts "RawBodyCapture: Captured #{body.length} bytes"

      # Create a new StringIO for the app to use
      env["rack.input"] = StringIO.new(body)
    end

    @app.call(env)
  end
end

# Add the raw body capture middleware FIRST
use RawBodyCapture

# Monkey-patch to disable HostAuthorization for ngrok
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
