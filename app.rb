# frozen_string_literal: true

require "sinatra"
require "json"
require "faraday"
require "dotenv/load"
require "openssl"
require "rack/utils"

# set :protection, false
set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 4567)

before do
  puts "HTTP_HOST => #{request.env['HTTP_HOST']}"
  puts "SERVER_NAME => #{request.env['SERVER_NAME']}"
end

# -----------------------------
# Configuration
# -----------------------------

ALLOWED_TEAM_IDS = %w[C093R1STRHT].freeze # teetime
ALLOWED_STAGES = %w[staging_one staging_two staging_three].freeze
REQUEST_TTL_SECONDS = 300 # 5 minutes

# -----------------------------
# Helpers
# -----------------------------

helpers do
  def json(body, status: 200)
    content_type :json
    halt status, body.to_json
  end

  # ---- Slack Authentication ----
  def verify_slack_request!
    # halt 403 unless ALLOWED_TEAM_IDS.include?(params[:team_id])

    timestamp = request.env["HTTP_X_SLACK_REQUEST_TIMESTAMP"]
    signature = request.env["HTTP_X_SLACK_SIGNATURE"]

    halt 401, "Missing Slack headers" unless timestamp && signature

    # Prevent replay attacks
    if (Time.now.to_i - timestamp.to_i).abs > REQUEST_TTL_SECONDS
      halt 401, "Stale Slack request"
    end

    body = request.body.read
    request.body.rewind

    basestring = "v0:#{timestamp}:#{body}"
    digest = OpenSSL::HMAC.hexdigest(
      "SHA256",
      ENV.fetch("SLACK_SIGNING_SECRET"),
      basestring
    )

    computed_signature = "v0=#{digest}"

    unless Rack::Utils.secure_compare(computed_signature, signature)
      halt 401, "Invalid Slack signature"
    end
  end

  # ---- GitHub Client ----
  def github_client
    @github_client ||= Faraday.new(
      url: "https://api.github.com",
      headers: {
        "Authorization" => "Bearer #{ENV.fetch("GITHUB_TOKEN")}",
        "Accept" => "application/vnd.github+json",
        "X-GitHub-Api-Version" => "2022-11-28",
        "Content-Type" => "application/json"
      }
    )
  end

  # ---- Trigger GitHub Actions ----
  def trigger_github_action(stage:, branch:)
    response = github_client.post do |req|
      req.url "/repos/#{ENV.fetch("GITHUB_REPO")}/actions/workflows/#{ENV.fetch("GITHUB_WORKFLOW")}/dispatches"
      req.body = {
        ref: "main",
        inputs: {
          stage: stage,
          branch: branch
        }
      }.to_json
    end

    return if response.success?

    raise "GitHub dispatch failed (#{response.status}): #{response.body}"
  end
end

# -----------------------------
# Routes
# -----------------------------

get "/" do
  status 200
  "OK"
end

post "/slack/deploy" do
  verify_slack_request!

  text = params[:text].to_s.strip
  stage, branch = text.split(/\s+/, 2)

  unless stage && branch
    return json(
      {
        response_type: "ephemeral",
        text: "Usage: /deploy <stage> <branch>\nExample: /deploy staging_two main"
      }
    )
  end

  unless ALLOWED_STAGES.include?(stage)
    return json(
      {
        response_type: "ephemeral",
        text: "Invalid stage. Allowed stages: #{ALLOWED_STAGES.join(', ')}"
      },
      status: 403
    )
  end

  unless branch.match?(/\A[\w\-\/\.]+\z/)
    return json(
      {
        response_type: "ephemeral",
        text: "Invalid branch name."
      },
      status: 400
    )
  end

  begin
    trigger_github_action(stage: stage, branch: branch)
  rescue => e
    return json(
      {
        response_type: "ephemeral",
        text: "Deployment failed to start.\n#{e.message}"
      },
      status: 500
    )
  end

  json(
    {
      response_type: "in_channel",
      text: <<~MSG.strip
        🚀 Deployment started
        • Stage: `#{stage}`
        • Branch: `#{branch}`
        • Triggered by: <@#{params[:user_id]}>
      MSG
    }
  )
end
