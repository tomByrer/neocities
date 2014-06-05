class Comment < Sequel::Model
  include Sequel::ParanoidDelete
  many_to_one :event
  many_to_one :actioning_site, class: :Site
  one_to_many :comment_likes

  def liking_site_names
    comment_likes_dataset.select(:id, :actioning_site_id).all.collect {|comment_like| comment_like.actioning_site_dataset.select(:username).first.username }
  end

  def site_likes?(site)
    comment_likes_dataset.filter(actioning_site_id: site.id).count > 0
  end

  def site_like(site)
    add_comment_like actioning_site_id: site.id
  end

  def site_unlike(site)
    comment_likes_dataset.filter(actioning_site_id: site.id).delete
  end

  def toggle_site_like(site)
    if site_likes? site
      site_unlike site
      false
    else
      site_like site
      true
    end
  end
end
