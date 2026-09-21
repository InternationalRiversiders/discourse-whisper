DiscourseWhisper::Engine.routes.draw do
    get "/" => "main#index"
    get "/state" => "main#state"
    post "/action" => "main#mutate"
    post "/upload" => "main#upload"
    get "/my-data" => "main#export"
    get "/legacy(/*path)" => "main#legacy"
    get "/media/:id" => "main#media"
  end
