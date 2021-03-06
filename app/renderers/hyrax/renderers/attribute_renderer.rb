require File.join( Gem::Specification.find_by_name("hyrax").full_gem_path, "app/renderers/hyrax/renderers/attribute_renderer.rb" )

module Hyrax
  module Renderers

    # monkey patch Hyrax::Renderers::AttributeRenderer
    class AttributeRenderer
      # TODO: add support for multiple work_types in options


      # Draw the dt row for the attribute
      def render_dt_row
        markup = ''
        return markup if values.blank? && !options[:include_empty]
        markup << %(<dt>#{label}</dt>\n<dd>)
        attributes = microdata_object_attributes(field).merge(class: "attribute attribute-#{field}")
        Array(values).each_with_index do |value,index|
          markup << %(<br/>\n) if index > 0
          markup << %(#{attribute_value_to_html(value.to_s)})
          markup << %(&nbsp;) if value.blank?
        end
        markup << %(</dd>)
        markup.html_safe
      end

    end

  end
end
