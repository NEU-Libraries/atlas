Apipie.configure do |config|
  config.app_name                = "Atlas"
  config.api_base_url            = "/api"
  config.doc_base_url            = "/apipie"
  # where is your API defined?
  config.api_controllers_matcher = "#{Rails.root}/app/controllers/**/*.rb"
  config.app_info["1.0"] = "
    Atlas is the API that drives DRS V2
  "
end
