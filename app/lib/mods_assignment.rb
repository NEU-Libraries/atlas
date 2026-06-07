# frozen_string_literal: true

module MODSAssignment
  def plain_title=(title_str)
    return if title_str.blank?

    mods_obj = Mods::Record.new.from_str(mods_xml)
    # TODO: Need to destroy greater title (subtitle) et. al. to effectively write a 'plain' title
    title_node = mods_obj.title_info.find { |n| n.attribute('usage')&.value == 'primary' }.title
    return if whitespace_equivalent?(title_node.text, title_str)

    title_node.content = title_str
    self.mods_xml = mods_obj.to_xml
  end

  def plain_description=(desc_str)
    mods_obj = Mods::Record.new.from_str(mods_xml)
    abstract_node = mods_obj.abstract.first
    return if whitespace_equivalent?(abstract_node&.content, desc_str)

    abstract_node.content = desc_str
    self.mods_xml = mods_obj.to_xml
  end

  private

    # Change-detection guard only. A descriptive PATCH writes a new MODS (OCFL)
    # version on every setter call, and Cerberus's simple form re-submits *all*
    # descriptive fields on every save — so without this guard a one-field edit
    # mints a version per field, including ones the user never touched.
    #
    # We treat values that differ *solely* by insignificant whitespace (NBSP vs
    # space, collapsible runs, leading/trailing space) as unchanged, because a
    # form round-trip routinely normalizes NBSP -> space on a field's pre-filled
    # value. That normalization is not a user edit and must not mint a version
    # (it is also content-mutating, so byte-identical coalescing can't catch it).
    #
    # This affects the change-detection compare ONLY: when the values genuinely
    # differ, the caller still writes the user's literal string verbatim.
    def whitespace_equivalent?(current, incoming)
      normalize_whitespace(current) == normalize_whitespace(incoming)
    end

    def normalize_whitespace(str)
      # \s does not match U+00A0 (NBSP) in Ruby's default regex mode, so fold it
      # to a plain space first, then collapse any whitespace run to one space.
      str.to_s.tr("\u00A0", ' ').gsub(/\s+/, ' ').strip
    end
end
