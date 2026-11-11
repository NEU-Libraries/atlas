# frozen_string_literal: true

# The preview Delegate's URI and what it says about its image, which every
# Modsable record carries. See docs/binaries.md.
preview = resource.delegate_for(Role.preview_image.name)
json.preview preview&.uri
json.preview_width preview&.width
json.preview_height preview&.height
json.preview_placeholder preview&.placeholder
