class Salesforce::ApiController < Admin::AdminController
  before_action :find_post
  attr_accessor :post

  def create_case
    begin
      Salesforce::Case.new(model: post, user: post.user).create!
      render json: success_json
    rescue => e
      render json: { errors: [e.message] }, status: 422
    end
  end

  def create_contact
    begin
      Salesforce::Contact.create!(model: post.user)
      render json: success_json
    rescue => e
      render json: { errors: [e.message] }, status: 422
    end
  end

  def find_post
    params.require(:post_id)
    @post = Post.find(params[:post_id])
  end
end
