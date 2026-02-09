# frozen_string_literal: true

require "sinatra"
require "json"
require "faraday"
require "dotenv/load"
require "openssl"
require "rack/utils"
require "stringio"

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 4567)

before do
  puts "HTTP_HOST => #{request.env['HTTP_HOST']}"
  puts "SERVER_NAME => #{request.env['SERVER_NAME']}"
end

# -----------------------------
# Configuration
# -----------------------------

GITHUB_REPO_PREFIX="teetime-co-jp"
ALLOWED_TEAM_IDS = %w[T0D62LCBV].freeze
ALLOWED_REPOS = %w[firstee golfee].freeze
TRIGGERED_BRANCH = {
  "firstee" => "master",
  "golfee" => "main"
}
ALLOWED_STAGES = %w[staging staging_one staging_two staging_three].freeze
REQUEST_TTL_SECONDS = 300

# -----------------------------
# Helpers
# -----------------------------

helpers do
  def json(body, status: 200)
    content_type :json
    halt status, body.to_json
  end

  def verify_slack_request!(team_id)
    halt 403 unless ALLOWED_TEAM_IDS.include?(team_id)

    timestamp = request.env["HTTP_X_SLACK_REQUEST_TIMESTAMP"]
    signature = request.env["HTTP_X_SLACK_SIGNATURE"]
    raw_body = request.env["rack.input.raw"]

    halt 401, "Missing Slack headers" unless timestamp && signature
    halt 401, "Missing raw body" unless raw_body

    if (Time.now.to_i - timestamp.to_i).abs > REQUEST_TTL_SECONDS
      halt 401, "Stale Slack request"
    end

    basestring = "v0:#{timestamp}:#{raw_body}"
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

  def trigger_github_action(repo:, stage:, branch:)
    request_body = {
      ref: "#{ENV.fetch("GITHUB_TRIGGER_BRANCH", TRIGGERED_BRANCH[repo])}",
      inputs: {
        stage: stage,
        branch: branch
      }
    }.to_json

    p "request body: #{request_body}"

    url = "/repos/#{GITHUB_REPO_PREFIX}/#{repo}/actions/workflows/#{ENV.fetch("GITHUB_WORKFLOW")}/dispatches"
    response = github_client.post do |req|
      req.url url
      req.body = request_body
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
  "OK v2"
end

post "/slack/deploy" do
  verify_slack_request!(params[:team_id])

  text = params[:text].to_s.strip
  repo, stage, branch = text.split(/\s+/, 3)

  unless repo && stage && branch
    return json(
      {
        response_type: "ephemeral",
        text: "Usage: /deploy <repo> <stage> <branch>\nExample: /deploy golfee staging_two main"
      }
    )
  end

  unless ALLOWED_REPOS.include?(repo)
    return json(
      {
        response_type: "ephemeral",
        text: "Invalid stage. Allowed stages: #{ALLOWED_REPOS.join(', ')}"
      },
    # status: 403
      )
  end

  unless ALLOWED_STAGES.include?(stage)
    return json(
      {
        response_type: "ephemeral",
        text: "Invalid stage. Allowed stages: #{ALLOWED_STAGES.join(', ')}"
      },
    # status: 403
      )
  end

  unless branch.match?(/\A[\w\-\/\.]+\z/)
    return json(
      {
        response_type: "ephemeral",
        text: "Invalid branch name."
      },
    # status: 400
      )
  end

  begin
    trigger_github_action(repo: repo, stage: stage, branch: branch)
  rescue => e
    error_msg = e.message

    p error_msg

    formatted_error = if error_msg.include?("401")
                        "❌ *Authentication Failed*\n\nThe GitHub token appears to be invalid or expired.\nPlease check your `GITHUB_TOKEN` configuration."
                      elsif error_msg.include?("404")
                        "❌ *Not Found*\n\nCouldn't find the repository or workflow.\nPlease verify:\n• Repo: `#{ENV['GITHUB_REPO']}`\n• Workflow: `#{ENV['GITHUB_WORKFLOW']}`"
                      elsif error_msg.include?("403")
                        "❌ *Permission Denied*\n\nThe GitHub token doesn't have permission to trigger workflows.\nMake sure the token has `workflow` scope."
                      else
                        "❌ *Deployment Failed*\n\n```#{error_msg}```"
                      end

    return json(
      {
        response_type: "ephemeral",
        text: formatted_error
      }
    )
  end

  json(
    {
      response_type: "in_channel",
      text: <<~MSG.strip
        🚀 Deployment started
        • Repo: `#{repo}`
        • Stage: `#{stage}`
        • Branch: `#{branch}`
        • Triggered by: <@#{params[:user_id]}>
      MSG
    }
  )
end
