# frozen_string_literal: true

# The OCFL storage root the suite writes binaries to, in one place so the
# :test_disk adapter and the specs that clear the root by name cannot diverge.
#
# Suffixed per parallel worker, on the same scheme as the test database:
# parallel_tests leaves TEST_ENV_NUMBER empty for the first worker and numbers
# the rest from 2, so an unsharded run keeps tmp/files. Several specs wipe this
# root mid-run to reset the NOID-to-path mapping, so two workers sharing one
# would delete each other's blobs.
module TestStorage
  def self.root
    Rails.root.join("tmp/files#{ENV.fetch('TEST_ENV_NUMBER', nil)}")
  end
end
