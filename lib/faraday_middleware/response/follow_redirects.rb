require 'faraday'
require 'set'


module FaradayMiddleware
  # Public: Exception thrown when the maximum amount of requests is exceeded.
  class RedirectLimitReached < Faraday::Error::ClientError
    attr_reader :response

    def initialize(response)
      super "too many redirects; last one to: #{response['location']}"
      @response = response
    end
  end

  # Public: Follow HTTP 301, 302, 303, and 307 redirects.
  #
  # For HTTP 301, 302, and 303, the original GET, POST, PUT, DELETE, or PATCH
  # request gets converted into a GET. With `:standards_compliant => true`,
  # however, the HTTP method after 301/302 remains unchanged. This allows you
  # to opt into HTTP/1.1 compliance and act unlike the major web browsers.
  #
  # This middleware currently only works with synchronous requests; i.e. it
  # doesn't support parallelism.
  class FollowRedirects < Faraday::Middleware
    # HTTP methods for which 30x redirects can be followed
    ALLOWED_METHODS = Set.new [:head, :options, :get, :post, :put, :patch, :delete]
    # HTTP redirect status codes that this middleware implements
    REDIRECT_CODES  = Set.new [301, 302, 303, 307]
    # Keys in env hash which will get cleared between requests
    ENV_TO_CLEAR    = Set.new [:status, :response, :response_headers]

    # Default value for max redirects followed
    FOLLOW_LIMIT = 3

    # Public: Initialize the middleware.
    #
    # options - An options Hash (default: {}):
    #           :limit               - A Numeric redirect limit (default: 3)
    #           :standards_compliant - A Boolean indicating whether to respect
    #                                  the HTTP spec when following 301/302
    #                                  (default: false)
    #           :cookies             - An Array of Strings (e.g.
    #                                  ['cookie1', 'cookie2']) to choose
    #                                  cookies to be kept, or :all to keep
    #                                  all cookies (default: []).
    def initialize(app, options = {})
      super(app)
      @options = options

      @convert_to_get = Set.new [303]
      @convert_to_get << 301 << 302 unless standards_compliant?

      @existing_cookies = {}
    end

    def call(env)
      perform_with_redirection(env, follow_limit)
    end

    private

    def convert_to_get?(response)
      ![:head, :options].include?(response.env[:method]) &&
        @convert_to_get.include?(response.status)
    end

    def perform_with_redirection(env, follows)
      request_body = env[:body]
      response = @app.call(env)

      response.on_complete do |env|
        if follow_redirect?(env, response)
          raise RedirectLimitReached, response if follows.zero?
          env = update_env(env, request_body, response)
          response = perform_with_redirection(env, follows - 1)
        end
      end
      response
    end

    def update_env(env, request_body, response)
      env[:url] += response['location']
      if @options[:cookies]
        cookies = keep_cookies(env)
        env[:request_headers][:cookies] = cookies unless cookies.nil?
      end

      if convert_to_get?(response)
        env[:method] = :get
        env[:body] = nil
      else
        env[:body] = request_body
      end

      ENV_TO_CLEAR.each {|key| env.delete key }

      env
    end

    def follow_redirect?(env, response)
      ALLOWED_METHODS.include? env[:method] and
        REDIRECT_CODES.include? response.status
    end

    def follow_limit
      @options.fetch(:limit, FOLLOW_LIMIT)
    end

    def keep_cookies(env)
      cookies = @options.fetch(:cookies, [])

      set_cookies = if env[:response_headers]["Set-Cookie"]
        indexed_by_name = {}

        env[:response_headers]["Set-Cookie"].split(", ").each do |cookie_string|
          # CGI::Cookie#parse returns a Hash where each value is a CGI::Cookie
          # object that serializes to the same thing.
          # So just grab the 1st value and work with that.
          cookie = CGI::Cookie.parse(cookie_string).values[0]
          indexed_by_name[cookie.name] = cookie
        end

        indexed_by_name
      end

      response_cookies = if env[:response_headers][:cookies]
        CGI::Cookie.parse env[:response_headers][:cookies]
      end

      all_cookies = if set_cookies && response_cookies
        response_cookies.merge set_cookies
      elsif set_cookies
        set_cookies
      elsif response_cookies
        response_cookies
      else
        {}
      end

      all_cookies = override_existing_cookies all_cookies

      returned_string = if cookies == :all
        all_cookies
      else
        sliced_hash = {}
        cookies.each do |cookie_name|
          if all_cookies[cookie_name]
            sliced_hash[cookie_name] = all_cookies[cookie_name]
          end
        end
        sliced_hash
      end.values.map do |cookie|
        "#{cookie.name}=#{cookie.value[0]}"
      end.join("; ")

      unless returned_string.empty?
        returned_string
      end
    end

    def selected_request_cookies(cookies)
      selected_cookies(cookies)[0...-1]
    end

    def selected_cookies(cookies)
      "".tap do |cookie_string|
        @options[:cookies].each do |cookie|
          string = /#{cookie}=?[^;]*/.match(cookies)[0] + ';'
          cookie_string << string
        end
      end
    end

    def override_existing_cookies new_cookies_hash
      @existing_cookies.merge! new_cookies_hash
    end

    def standards_compliant?
      @options.fetch(:standards_compliant, false)
    end
  end
end
