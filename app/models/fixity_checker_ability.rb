# frozen_string_literal: true

# The rolling fixity checker's whole ability: read its due list and record
# results. A class of its own rather than a branch in Ability, so no rule added
# there can ever reach the checker. ApplicationController#current_ability picks
# it. See docs/fixity.md.
class FixityCheckerAbility
  include CanCan::Ability

  def initialize(_user = nil, **)
    can %i[read_due record], :fixity_check
  end
end
