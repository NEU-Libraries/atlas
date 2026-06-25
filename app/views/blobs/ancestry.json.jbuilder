# frozen_string_literal: true

# Blob → parent FileSet → parent Work noids. Flat { file_set:, work: } so a
# consumer (Cerberus impression capture) can roll a download up to its
# containing Work from the blob id alone. Either is null when unresolvable
# (orphan blob, or a non-content blob whose ancestor isn't a FileSet/Work).
json.file_set @file_set&.noid
json.work @work&.noid
