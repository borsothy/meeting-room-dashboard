require 'rubygems'
require 'sinatra'
require 'sinatra-websocket'
require 'googleauth'
require 'googleauth/stores/redis_token_store'
require 'google/apis/calendar_v3'
require 'google-id-token'
require 'dotenv'
require 'json'

LOGIN_URL = '/'

set :server, 'thin'
set :sockets, []

configure do
  Dotenv.load

  Google::Apis::ClientOptions.default.application_name = 'Ruby client samples'
  Google::Apis::ClientOptions.default.application_version = '0.9'
  Google::Apis::RequestOptions.default.retries = 3

  enable :sessions
  set :show_exceptions, false
  set :client_id, Google::Auth::ClientId.new(ENV['GOOGLE_CLIENT_ID'],
                                             ENV['GOOGLE_CLIENT_SECRET'])
  set :token_store, Google::Auth::Stores::RedisTokenStore.new(redis: Redis.new)
end

helpers do
  # Returns credentials authorized for the requested scopes. If no credentials are available,
  # redirects the user to authorize access.
  def credentials_for(scope)
    authorizer = Google::Auth::WebUserAuthorizer.new(settings.client_id, scope, settings.token_store)
    user_id = session[:user_id]
    redirect LOGIN_URL if user_id.nil?
    credentials = authorizer.get_credentials(user_id, request)
    if credentials.nil?
      redirect authorizer.get_authorization_url(login_hint: user_id, request: request)
    end
    credentials
  end

  def resize(url, width)
    url.sub(/s220/, sprintf('s%d', width))
  end
end

# Home page
get('/') do
  @client_id = settings.client_id.id
  erb :home
end

# Log in the user by validating the identity token generated by the Google Sign-In button.
# This checks that the token is signed by Google, current, and is intended for this application.
#
post('/signin') do
  audience = settings.client_id.id
  # Important: The google-id-token gem is not production ready. If using, consider fetching and
  # supplying the valid keys separately rather than using the built-in certificate fetcher.
  validator = GoogleIDToken::Validator.new
  claim = validator.check(params['id_token'], audience, audience)
  if claim
    session[:user_id] = claim['sub']
    session[:user_email] = claim['email']
    200
  else
    logger.info('No valid identity token present')
    401
  end
end

def get_events(calendar_id)
  day_start = (Date.today)
  day_end = (Date.today+1)
  calendar = Google::Apis::CalendarV3::CalendarService.new
  calendar.authorization = credentials_for(Google::Apis::CalendarV3::AUTH_CALENDAR)
  g_events = calendar.list_events(calendar_id,
                                 single_events: true,
                                 order_by: 'startTime',
                                 time_min: day_start.rfc3339,
                                 time_max: day_end.rfc3339,
                                 time_zone: 'Europe/Budapest',
                                 fields: 'items(summary,start,end),summary')
  p g_events
  events = g_events.items.map do |event|
    {
      name: event.summary,
      start: event.start.date_time,
      end: event.end.date_time
    }
  end
  calendar_name = g_events.summary
  {room_name: calendar_name, events: events}.to_json
end

get '/calendar' do
  return erb :dashboard unless request.websocket?
  request.websocket do |ws|
    ws.onopen do
      settings.sockets << ws
      EM.next_tick{ ws.send(get_events('cheppers.com_2d32353038373534353337@resource.calendar.google.com')) }
    end
    ws.onmessage do |msg|

    end
    ws.onclose do
      settings.sockets.delete(ws)
    end
  end
end

# Callback for authorization requests. This saves the autorization code and
# redirects back to the URL that originally requested authorization. The code is
# redeemed on the next request.
#
# Important: While the deferred approach is generally easier, it doesn't play well
# with developer mode and sinatra's default cookie-based session implementation. Changes to the
# session state are lost if the page doesn't render due to error, which can lead to further
# errors indicating the code has already been redeemed.
#
# Disabling show_exceptions or using a different session provider (E.g. Rack::Session::Memcache)
# avoids the issue.
get('/oauth2callback') do
  target_url = Google::Auth::WebUserAuthorizer.handle_auth_callback_deferred(request)
  redirect target_url
end
