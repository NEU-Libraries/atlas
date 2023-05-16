# frozen_string_literal: true

class ApplicationService
  include MODSBuilder
  include NoidHelper

  def self.call(**kwargs)
    new(**kwargs).call
  end
end
