# frozen_string_literal: true

module ::Salesforce
  # The Salesforce fields the plugin writes (Case.Description,
  # CaseComment.CommentBody, FeedItem.Body) are plain text: raw markdown shows
  # its syntax and upload:// references are dead, while HTML would show its
  # tags. Rendering the cooked post down to plain text keeps the words readable
  # and resolves every link and upload to a full URL.
  module PostContent
    def self.body_for(post, max_length: nil)
      return post.raw if !SiteSetting.salesforce_send_rendered_post_content

      text = plain_text(post)
      max_length ? text.truncate(max_length) : text
    end

    def self.plain_text(post)
      html = PrettyText.format_for_email(post.cooked, post)
      doc = Nokogiri::HTML5.fragment(html)

      doc.css("a.anchor").each(&:remove)
      doc.css("img.emoji").each { |img| img.replace(text_node(doc, img["alt"].to_s)) }
      # A lightboxed image links its optimized rendition to the original; the
      # original is the only URL worth sending.
      doc
        .css("a.lightbox")
        .each do |a|
          label = a.at_css("img")&.[]("alt").presence
          a.replace(text_node(doc, "\n#{label ? "#{label}: " : ""}#{absolute(a["href"])}\n"))
        end
      doc
        .css("img")
        .each do |img|
          src = absolute(img["src"])
          label = img["alt"].presence
          img.replace(text_node(doc, "\n#{label && label != src ? "#{label}: " : ""}#{src}\n"))
        end
      doc
        .css("a")
        .each do |a|
          href = absolute(a["href"])
          label = a.text.strip
          a.replace(text_node(doc, label.blank? || label == href ? href : "#{label} (#{href})"))
        end
      doc.css("li").each { |li| li.prepend_child(text_node(doc, "- ")) }
      doc.css("br").each { |br| br.replace(text_node(doc, "\n")) }
      doc
        .css("p, div, h1, h2, h3, h4, h5, h6, li, blockquote, pre, ul, ol, aside, table, tr")
        .each { |node| node.add_next_sibling(text_node(doc, "\n")) }

      doc.text.gsub(/[ \t]+\n/, "\n").gsub(/\n{3,}/, "\n\n").strip
    end

    # Cooked image sources come through relative or protocol-relative, which
    # nothing outside a browser can resolve.
    def self.absolute(url)
      url = url.to_s
      if url.start_with?("//")
        "#{Discourse.base_protocol}:#{url}"
      elsif url.start_with?("/")
        "#{Discourse.base_url}#{url}"
      else
        url
      end
    end
    private_class_method :absolute

    def self.text_node(doc, text)
      Nokogiri::XML::Text.new(text, doc.document)
    end
    private_class_method :text_node
  end
end
