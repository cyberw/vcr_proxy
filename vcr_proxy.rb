require 'net/http'
require 'webrick'
require 'webrick/https'
require 'webrick/httpproxy'
require 'vcr'
#require 'debugger'

# enable modifications to unparsed_uri
class WEBrick::HTTPRequest
  def unparsed_uri=(str)
    @unparsed_uri = str
  end
end

class VCRProxy < WEBrick::HTTPProxyServer
  def initialize(options)
    super(options)
    @mitm_port = options[:MITMPort] || 12322
  end

  # starts the MITM server
  def start_ssl_mitm(host, port)
    # WORKAROUND for "adress is already in use", just increase
    # the port number and kill the old webrick
    @mitm_port += 1
    @mitm_server.stop if @mitm_server
    @mitm_thread.kill if @mitm_thread

    @mitm_server = WEBrick::HTTPServer.new(:Port => @mitm_port,
    :SSLEnable => true,
    :SSLVerifyClient => ::OpenSSL::SSL::VERIFY_NONE,
    :SSLCertName => [["C", "US"], ["O", host], ["CN", host] ])

    @mitm_server.mount_proc('/') do |req,res|
      method, url, version = req.request_line.split(" ")

      remote_request = case method.upcase
      when 'GET'
        Net::HTTP::Get.new(req.unparsed_uri)
      when 'POST'
        Net::HTTP::Post.new(req.unparsed_uri)
      when 'PUT'
        Net::HTTP::Put.new(req.unparsed_uri)
      when 'DELETE'
        Net::HTTP::Delete.new(req.unparsed_uri)
      when 'HEAD'
        Net::HTTP::Head.new(req.unparsed_uri)
      when 'OPTIONS'
        Net::HTTP::Options.new(req.unparsed_uri)
      else
        puts "HTTP method '#{method}' not supported!"
      end

      remote_request.body = req.body
      remote_request.body = req.body
      remote_request.initialize_http_header(transform_header(req.header))

      uri = req.request_uri
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE

      remote_response = http.request(remote_request)

      remote_response.code
      res.body = remote_response.body
      res.status = remote_response.code

      remote_response.header.each do |k|
        # next if k == 'content-length' # if content-length is invalid then the response gets truncated. We dont want that, even if it is probably an error in the SUT..
        res.header[k] = if k == 'content-length'
                          res.body.length
                        else
                          remote_response.header[k]
                        end
      end
    end

    @mitm_thread = Thread.new { @mitm_server.start }
  end

  # transforms the webrick header format into the ruby net http format
  # webrick:  {"agent"=>["blabla"]}
  # net http: {"agent"=>"blabla"}
  def transform_header header
    h = {}
    header.each do |key, value|
      if value.class == Array
        h[key] = value.first
      else
        h[key] = value
      end
    end
    h
  end

  # the proxy tries to just forward SSL connections with a "CONNECT"
  # catch that forwarding, and call ssl_mitm
  def do_CONNECT(req, res)
    host, port = req.unparsed_uri.split(":")
    port = 443 unless port
    start_ssl_mitm(host, port)
    req.unparsed_uri = "127.0.0.1:#{@mitm_port}"
    super req, res
  end

  def service(req, res)
    super(req, res)
  end
end

VCR.configure do |c|
  c.hook_into :webmock
  c.cassette_library_dir = 'cassettes'
  c.default_cassette_options = { :record => :new_episodes }
  c.ignore_localhost = true
  c.ignore_hosts "127.0.0.1"
  # c.debug_logger = $stderr
end

server = VCRProxy.new(:Port => 9999)
trap("INT"){ server.shutdown }

raise 'Please specify a cassette name.' if ARGV.length < 1

VCR.use_cassette(ARGV[0]) do
  server.start
end
