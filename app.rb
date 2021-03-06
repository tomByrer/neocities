require 'base64'
require 'uri'
require 'net/http'
require './environment.rb'

use Rack::Session::Cookie, key:          'neocities',
                           path:         '/',
                           expire_after: 31556926, # one year in seconds
                           secret:       $config['session_secret']

use Rack::Recaptcha, public_key: $config['recaptcha_public_key'], private_key: $config['recaptcha_private_key']
helpers Rack::Recaptcha::Helpers

before do
  if request.path.match /^\/api\//i
    @api = true
    content_type :json
  elsif request.path.match /^\/stripe_webhook$/
    # Skips the CSRF check for stripe web hooks
  else
    content_type :html, 'charset' => 'utf-8'
    redirect '/' if request.post? && !csrf_safe?
  end
end

not_found do
  erb :'not_found'
end

error do
  EmailWorker.perform_async({
    from: 'web@neocities.org',
    to: 'errors@neocities.org',
    subject: "[NeoCities Error] #{env['sinatra.error'].class}: #{env['sinatra.error'].message}",
    body: "#{request.request_method} #{request.path}\n\n" +
          (current_site ? "Site: #{current_site.username}\nEmail: #{current_site.email}\n\n" : '') +
          env['sinatra.error'].backtrace.join("\n")
  })

  if @api
    api_error 500, 'server_error', 'there has been an unknown server error, please try again later', 500
  end

  erb :'error'
end

get '/newindex_mockup' do
  if SimpleCache.expired?(:sites_count)
    @sites_count = SimpleCache.store :sites_count, Site.count.roundup(100), 600 # 10 Minutes
  else
    @sites_count = SimpleCache.get :sites_count
  end

  erb :newindex_mockup, layout: false
end

get '/home_mockup' do
  erb :'home_mockup'
end

get '/edit_mockup' do
  erb :'edit_mockup'
end

get '/profile_mockup' do
  erb :'profile_mockup'
end

get '/tags_mockup' do
  erb :'tags_mockup'
end

get '/browse_mockup' do
  erb :'browse_mockup'
end

get '/tips_mockup' do
  erb :'tips_mockup'
end

get '/stats_mockup' do
  erb :'stats_mockup'
end

get '/?' do
  if SimpleCache.expired?(:sites_count)
    @sites_count = SimpleCache.store :sites_count, Site.count.roundup(100), 600 # 10 Minutes
  else
    @sites_count = SimpleCache.get :sites_count
  end

  erb :index, layout: false
end

get '/plan/?' do
  erb :'plan/index'
end

post '/plan/create' do
  require_login

  DB.transaction do
    customer = Stripe::Customer.create(
      card: params[:stripe_token],
      description: current_site.username,
      email: current_site.email,
      plan: params[:selected_plan]
    )
    current_site.stripe_customer_id = customer.id
    current_site.plan_ended = false
    current_site.save

    plan_name = customer.subscriptions.first['plan']['name']

    EmailWorker.perform_async({
      from: 'web@neocities.org',
      reply_to: current_site.email,
      to: 'contact@neocities.org',
      subject: "[NeoCities] You've become a supporter!",
      body: Tilt.new('./views/templates/email_subscription.erb', pretty: true).render(self, plan_name: plan_name)
    })
  end

  redirect '/plan'
end

def get_plan_name(customer_id)
  subscriptions = Stripe::Customer.retrieve(current_site.stripe_customer_id).subscriptions.all
  @plan_name = subscriptions.first.plan.name
end

get '/plan/manage' do
  require_login
  redirect '/plan' unless current_site.supporter? && !current_site.plan_ended
  @title = 'Manage Plan'
  @plan_name = get_plan_name current_site.stripe_customer_id
  erb :'plan/manage'
end

get '/plan/end' do
  require_login
  redirect '/plan'  unless current_site.supporter? && !current_site.plan_ended
  @title = 'End Plan'
  @plan_name = get_plan_name current_site.stripe_customer_id
  erb :'plan/end'
end

post '/plan/end' do
  require_login
  redirect '/plan'  unless current_site.supporter? && !current_site.plan_ended

  recaptcha_is_valid = ENV['RACK_ENV'] == 'test' || recaptcha_valid?

  if !recaptcha_is_valid
    @error = 'Recaptcha was filled out incorrectly, please try re-entering.'
    @plan_name = get_plan_name current_site.stripe_customer_id
    halt erb :'plan/end'
  end

  customer = Stripe::Customer.retrieve current_site.stripe_customer_id
  subscriptions = customer.subscriptions.all

  DB.transaction do
    subscriptions.each do |subscription|
      customer.subscriptions.retrieve(subscription.id).delete
    end
    current_site.plan_ended = true
    current_site.save
  end

  redirect '/plan'
end

get '/site/:username/tip' do |username|
  @site = Site[username: username]
  @title = "Tip #{@site.title}"
  erb :'tip'
end

get '/browse' do
  @current_page = params[:current_page]
  @current_page = @current_page.to_i
  @current_page = 1 if @current_page == 0

  site_dataset = Site.filter(is_banned: false, is_crashing: false).filter(site_changed: true).paginate(@current_page, 300)

  case params[:sort_by]
    when 'hits'
      site_dataset.order!(:hits.desc)
    when 'newest'
      site_dataset.order!(:created_at.desc)
    when 'oldest'
      site_dataset.order!(:created_at)
    when 'random'
      site_dataset.where! 'random() < 0.01'
    else
      params[:sort_by] = 'last_updated'
      site_dataset.order!(:updated_at.desc, :hits.desc)
  end

  site_dataset.filter! is_nsfw: (params[:is_nsfw] == 'true' ? true : false)

  @page_count = site_dataset.page_count || 1
  @sites = site_dataset.all
  erb :browse
end

get '/api' do
  erb :'api'
end

get '/tutorials' do
  erb :'tutorials'
end

get '/donate' do
  erb :'donate'
end

get '/blog' do
  expires 500, :public, :must_revalidate
  return Net::HTTP.get_response(URI('http://blog.neocities.org')).body
end

get '/blog/:article' do |article|
  expires 500, :public, :must_revalidate
  return Net::HTTP.get_response(URI("http://blog.neocities.org/#{article}.html")).body
end

get '/new' do
  dashboard_if_signed_in
  @site = Site.new
  @site.username = params[:username] unless params[:username].nil?
  erb :'new'
end

post '/create' do
  dashboard_if_signed_in
  @site = Site.new(
    username: params[:username],
    password: params[:password],
    email: params[:email],
    new_tags: params[:tags],
    is_nsfw: params[:is_nsfw],
    ip: request.ip
  )

  recaptcha_is_valid = ENV['RACK_ENV'] == 'test' || recaptcha_valid?

  if @site.valid? && recaptcha_is_valid
    DB.transaction do
      if !params[:stripe_token].nil? && params[:stripe_token] != ''
        customer = Stripe::Customer.create(
          card: params[:stripe_token],
          description: @site.username,
          email: @site.email,
          plan: params[:selected_plan]
        )
        @site.stripe_customer_id = customer.id
      end

      @site.save
    end

    session[:id] = @site.id
    redirect '/dashboard'
  else
    @site.errors.add :captcha, 'You must type in the two words correctly! Try again.' if !recaptcha_is_valid

    erb :'/new'
  end
end

get '/dashboard' do
  require_login
  erb :'dashboard'
end

get '/signin' do
  dashboard_if_signed_in
  erb :'signin'
end

get '/settings' do
  require_login
  slim :'settings'
end

post '/signin' do
  dashboard_if_signed_in

  if Site.valid_login? params[:username], params[:password]
    site = Site[username: params[:username]]

    if site.is_banned
      flash[:error] = 'Invalid login.'
      flash[:username] = params[:username]
      redirect '/signin'
    end

    session[:id] = site.id
    redirect '/dashboard'
  else
    flash[:error] = 'Invalid login.'
    flash[:username] = params[:username]
    redirect '/signin'
  end
end

get '/signout' do
  require_login
  session[:id] = nil
  redirect '/'
end

get '/about' do
  erb :'about'
end

get '/site_files/new_page' do
  require_login
  slim :'site_files/new_page'
end

post '/change_password' do
  require_login

  if !Site.valid_login?(current_site.username, params[:current_password])
    current_site.errors.add :password, 'Your provided password does not match the current one.'
    halt slim(:'settings')
  end

  current_site.password = params[:new_password]
  current_site.valid?

  if params[:new_password] != params[:new_password_confirm]
    current_site.errors.add :password, 'New passwords do not match.'
  end

  if current_site.errors.empty?
    current_site.save
    flash[:success] = 'Successfully changed password.'
    redirect '/settings'
  else
    halt slim(:'settings')
  end
end

post '/change_name' do
  require_login
  old_username = current_site.username

  if params[:name] == nil || params[:name] == ''
    flash[:error] = 'Name cannot be blank.'
    redirect '/settings'
  end

  if old_username == params[:name]
    flash[:error] = 'You already have this name.'
    redirect '/settings'
  end

  current_site.username = params[:name]

  if current_site.valid?
    DB.transaction {
      current_site.save
      current_site.move_files_from old_username
    }

    flash[:success] = "Site/user name has been changed. You will need to use this name to login, <b>don't forget it</b>."
    redirect '/settings'
  else
    halt slim(:'settings')
  end
end

post '/change_nsfw' do
  require_login
  current_site.update is_nsfw: params[:is_nsfw]
  redirect '/settings'
end

post '/site_files/create_page' do
  require_login
  @errors = []

  params[:pagefilename].gsub!(/[^a-zA-Z0-9_\-.]/, '')
  params[:pagefilename].gsub!(/\.html$/i, '')

  if params[:pagefilename].nil? || params[:pagefilename].empty?
    @errors << 'You must provide a file name.'
    halt slim(:'site_files/new_page')
  end

  name = "#{params[:pagefilename]}.html"

  if current_site.file_exists?(name)
    @errors << %{Web page "#{name}" already exists! Choose another name.}
    halt slim(:'site_files/new_page')
  end

  current_site.install_new_html_file name

  flash[:success] = %{#{name} was created! <a style="color: #FFFFFF; text-decoration: underline" href="/site_files/text_editor/#{name}">Click here to edit it</a>.}

  redirect '/dashboard'
end

get '/site_files/new' do
  require_login
  slim :'site_files/new'
end

get '/site_files/upload' do
  require_login
  slim :'site_files/upload'
end

def file_upload_response(error=nil)
  http_error_code = 406

  if params[:from_button]
    if error
      @error = error
      halt 200, erb(:'dashboard')
    else
      redirect '/dashboard'
    end
  else
    halt http_error_code, error if error
    halt 200, 'File(s) successfully uploaded.'
  end
end

post '/site_files/upload' do
  require_login
  @errors = []
  http_error_code = 406

  if params[:files].nil?
    file_upload_response "Uploaded files were not seen by the server, cancelled. We don't know what's causing this yet. Please contact us so we can help fix it. Thanks!"
  end

  params[:files].each do |file|
    if current_site.file_size_too_large? file[:tempfile].size
      file_upload_response "#{file[:filename]} is too large, upload cancelled."
    end

    if !Site.valid_file_type? file
      file_upload_response "#{file[:filename]}: file type is not allowed on Neocities, upload cancelled."
    end
  end

  uploaded_size = params[:files].collect {|f| f[:tempfile].size}.inject{|sum,x| sum + x }

  if current_site.file_size_too_large? uploaded_size
    file_upload_response "File(s) do not fit in your available space, upload cancelled."
  end

  params[:files].each do |file|
    current_site.store_file Site.sanitize_filename(file[:filename]), file[:tempfile]
  end

  current_site.increment_changed_count

  file_upload_response
end

post '/site_files/delete' do
  require_login
  sanitized_filename = Site.sanitize_filename params[:filename]

  current_site.delete_file(sanitized_filename)

  flash[:success] = "Deleted file #{params[:filename]}."
  redirect '/dashboard'
end

get '/site_files/:username.zip' do |username|
  require_login
  zipfile = current_site.files_zip
  content_type 'application/octet-stream'
  attachment   "#{current_site.username}.zip"
  zipfile
end

get '/site_files/download/:filename' do |filename|
  require_login
  content_type 'application/octet-stream'
  attachment filename
  current_site.get_file filename
end

get '/site_files/text_editor/:filename' do |filename|
  require_login
  begin
    @file_data = current_site.get_file filename
  rescue Errno::ENOENT
    flash[:error] = 'We could not find the requested file.'
    redirect '/dashboard'
  end
  slim :'site_files/text_editor', indent: false
end

post '/site_files/save/:filename' do |filename|
  require_login_ajax

  tempfile = Tempfile.new 'neocities_saving_file'

  input = request.body.read
  tempfile.set_encoding input.encoding
  tempfile.write input
  tempfile.close

  if current_site.file_size_too_large? tempfile.size
    halt 'File is too large to fit in your space, it has NOT been saved. Please make a local copy and then try to reduce the size.'
  end

  sanitized_filename = Site.sanitize_filename filename

  current_site.store_file sanitized_filename, tempfile

  'ok'
end

get '/site_files/allowed_types' do
  erb :'site_files/allowed_types'
end

get '/terms' do
  erb :'terms'
end

get '/privacy' do
  erb :'privacy'
end

get '/admin' do
  require_admin
  @banned_sites = Site.select(:username).filter(is_banned: true).order(:username).all
  @nsfw_sites = Site.select(:username).filter(is_nsfw: true).order(:username).all
  slim :'admin'
end

post '/admin/banip' do
  require_admin
  site = Site[username: params[:username]]

  if site.nil?
    flash[:error] = 'User not found'
    redirect '/admin'
  end

  if site.ip.nil? || site.ip.empty?
    flash[:error] = 'IP is blank, cannot continue'
    redirect '/admin'
  end

  sites = Site.filter(ip: site.ip, is_banned: false).all
  sites.each {|s| s.ban!}
  flash[:error] = "#{sites.length} sites have been banned."
  redirect '/admin'
end

post '/admin/banhammer' do
  require_admin

  site = Site[username: params[:username]]

  if site.nil?
    flash[:error] = 'User not found'
    redirect '/admin'
  end

  if site.is_banned
    flash[:error] = 'User is already banned'
    redirect '/admin'
  end

  site.ban!

  flash[:success] = 'MISSION ACCOMPLISHED'
  redirect '/admin'
end

post '/admin/mark_nsfw' do
  require_admin
  site = Site[username: params[:username]]

  if site.nil?
    flash[:error] = 'User not found'
    redirect '/admin'
  end

  site.is_nsfw = true
  site.save validate: false

  flash[:success] = 'MISSION ACCOMPLISHED'
  redirect '/admin'
end

get '/password_reset' do
  erb :'password_reset'
end

post '/send_password_reset' do
  sites = Site.filter(email: params[:email]).all

  if sites.length > 0
    token = SecureRandom.uuid.gsub('-', '')
    sites.each do |site|
      site.update password_reset_token: token
    end

    body = <<-EOT
Hello! This is the NeoCities cat, and I have received a password reset request for your e-mail address. Purrrr.

Go to this URL to reset your password: http://neocities.org/password_reset_confirm?token=#{token}

After clicking on this link, your password for all the sites registered to this email address will be changed to this token.

Token: #{token}

If you didn't request this reset, you can ignore it. Or hide under a bed. Or take a nap. Your call.

Meow,
the NeoCities Cat
    EOT

    body.strip!

    EmailWorker.perform_async({
      from: 'web@neocities.org',
      to: params[:email],
      subject: '[NeoCities] Password Reset',
      body: body
    })
  end

  flash[:success] = 'If your email was valid (and used by a site), the NeoCities Cat will send an e-mail to your account with password reset instructions.'
  redirect '/'
end

get '/password_reset_confirm' do
  if params[:token].nil? || params[:token].empty?
    flash[:error] = 'Could not find a site with this token.'
    redirect '/'
  end

  reset_site = Site[password_reset_token: params[:token]]

  if reset_site.nil?
    flash[:error] = 'Could not find a site with this token.'
    redirect '/'
  end

  sites = Site.filter(email: reset_site.email).all

  if sites.length > 0
    sites.each do |site|
      site.password = reset_site.password_reset_token
      site.save
    end

    flash[:success] = 'Your password for all sites with your email address has been changed to the token sent in your e-mail. Please login and change your password as soon as possible.'
  else
    flash[:error] = 'Could not find a site with this token.'
  end

  redirect '/'
end

get '/custom_domain' do
  require_login
  slim :custom_domain
end

post '/custom_domain' do
  require_login
  current_site.domain = params[:domain]

  if current_site.valid?
    current_site.save
    flash[:success] = 'The domain has been successfully updated.'
    redirect '/custom_domain'
  else
    slim :custom_domain
  end
end

get '/contact' do
  erb :'contact'
end

post '/contact' do

  @errors = []

  if params[:email].empty? || params[:subject].empty? || params[:body].empty?
    @errors << 'Please fill out all fields'
  end

  if !recaptcha_valid?
    @errors << 'Captcha was not filled out (or was filled out incorrectly)'
  end

  if !@errors.empty?
    erb :'contact'
  else
    EmailWorker.perform_async({
      from: 'web@neocities.org',
      reply_to: params[:email],
      to: 'contact@neocities.org',
      subject: "[NeoCities Contact]: #{params[:subject]}",
      body: params[:body]
    })

    flash[:success] = 'Your contact has been sent.'
    redirect '/'
  end
end

post '/stripe_webhook' do
  event = JSON.parse request.body.read
  if event['type'] == 'customer.created'
    username  = event['data']['object']['description']
    email     = event['data']['object']['email']
  end
  'ok'
end

post '/api/upload' do
  require_api_credentials

  files = []

  params.each do |k,v|
    next unless v.is_a?(Hash) && v[:tempfile]
    filename = k.to_s
    api_error(400, 'bad_filename', "#{filename} is not a valid filename, files not uploaded") unless Site.valid_filename? filename
    files << {filename: filename, tempfile: v[:tempfile]}
  end

  api_error 400, 'missing_files', 'you must provide files to upload' if files.empty?

  uploaded_size = files.collect {|f| f[:tempfile].size}.inject{|sum,x| sum + x }

  if current_site.file_size_too_large? uploaded_size
    api_error 400, 'too_large', 'files are too large to fit in your space, try uploading smaller (or less) files'
  end

  files.each do |file|
    if !Site.valid_file_type?(file)
      api_error 400, 'invalid_file_type', "#{file[:filename]} is not a valid file type, files have not been uploaded"
    end
  end

  files.each do |file|
    current_site.store_file file[:filename], file[:tempfile]
  end

  current_site.increment_changed_count

  api_success 'your file(s) have been successfully uploaded'
end

post '/api/delete' do
  require_api_credentials

  api_error 400, 'missing_filenames', 'you must provide files to delete' if params[:filenames].nil? || params[:filenames].empty?

  filenames = []

  params[:filenames].each do |filename|
    unless filename.is_a?(String) && Site.valid_filename?(filename)
      api_error 400, 'bad_filename', "#{filename} is not a valid filename, canceled deleting"
    end

    if !current_site.file_exists?(filename)
      api_error 400, 'missing_files', "#{filename} was not found on your site, canceled deleting"
    end

    if filename == 'index.html'
      api_error 400, 'cannot_delete_index', 'you cannot delete your index.html file, canceled deleting'
    end

    filenames << filename
  end

  filenames.each do |filename|
    current_site.delete_file(filename)
  end

  api_success 'file(s) have been deleted'
end

get '/api/info' do
  if params[:sitename]
    site = Site[username: params[:sitename]]

    api_error 400, 'site_not_found', "could not find site #{params[:sitename]}" if site.nil? || site.is_banned
    api_success api_info_for(site)
  else
    init_api_credentials
    api_success api_info_for(current_site)
  end
end

def api_info_for(site)
  {
    info: {
      sitename: site.username,
      hits: site.hits,
      created_at: site.created_at.rfc2822,
      last_updated: site.updated_at.rfc2822,
      domain: site.domain,
      tags: site.tags.collect {|t| t.name}
    }
  }
end

# Catch-all for missing api calls

get '/api/:name' do
  api_not_found
end

post '/api/:name' do
  api_not_found
end

def require_admin
  redirect '/' unless signed_in? && current_site.is_admin
end

def dashboard_if_signed_in
  redirect '/dashboard' if signed_in?
end

def require_login_ajax
  halt 'You are not logged in!' unless signed_in?
end

def csrf_safe?
  csrf_token == params[:csrf_token] || csrf_token == request.env['HTTP_X_CSRF_TOKEN']
end

def csrf_token
   session[:_csrf_token] ||= SecureRandom.base64(32)
end

def require_login
  redirect '/' unless signed_in?
end

def signed_in?
  !session[:id].nil?
end

def current_site
  @site ||= Site[id: session[:id]]
end

def title
  out = "NeoCities"
  return out                  if request.path == '/'
  return "#{out} - #{@title}" if @title
  "#{out} - #{request.path.gsub('/', '').capitalize}"
end

def encoding_fix(file)
  begin
    Rack::Utils.escape_html file
  rescue ArgumentError => e
    return Rack::Utils.escape_html(file.force_encoding('BINARY')) if e.message =~ /invalid byte sequence in UTF-8/
    fail
  end
end

def require_api_credentials
  if !request.env['HTTP_AUTHORIZATION'].nil?
    init_api_credentials
  else
    api_error_invalid_auth
  end
end

def init_api_credentials
  auth = request.env['HTTP_AUTHORIZATION']

  begin
    user, pass = Base64.decode64(auth.match(/Basic (.+)/)[1]).split(':')
  rescue
    api_error_invalid_auth
  end

  if Site.valid_login? user, pass
    site = Site[username: user]

    if site.nil? || site.is_banned
      api_error_invalid_auth
    end

    session[:id] = site.id
  else
    api_error_invalid_auth
  end
end

def api_success(message_or_obj)
  output = {result: 'success'}

  if message_or_obj.is_a?(String)
    output[:message] = message_or_obj
  else
    output.merge! message_or_obj
  end

  api_response(200, output)
end

def api_response(status, output)
  halt status, JSON.pretty_generate(output)+"\n"
end

def api_error(status, error_type, message)
  api_response(status, result: 'error', error_type: error_type, message: message)
end

def api_error_invalid_auth
  api_error 403, 'invalid_auth', 'invalid credentials - please check your username and password'
end

def api_not_found
  api_error 404, 'not_found', 'the requested api call does not exist'
end