
module Hyrax
  class AnonymousLinkSearchBuilder < ::SearchBuilder
    include Hyrax::SingleResult
    self.default_processor_chain = [:find_one]
  end
end
