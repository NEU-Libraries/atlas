# frozen_string_literal: true

# Measures whether a directory can host an OCFL storage root.
#
# The adapter speaks POSIX and nothing else, deliberately: POSIX is the one
# interface local disk, a NAS, and every mounted object store can present, so
# keeping to it is what keeps the destination for preservation storage an open
# question. That only works if the demands are written down and testable, which
# is what this is. The numbering matches the eight requirements in the storage
# root pool report.
#
# It measures capability, not guarantees. Nothing here can prove a rename is
# atomic or that fsync reached the platter — that needs crash injection. A
# substrate that fails a check is disqualified; one that passes is only not yet
# disqualified.
class SubstrateConformance < ApplicationService
  Check = Struct.new(:id, :name, :required, :ok, :detail, keyword_init: true)

  # id, name, and the private method that measures it. A nil method is a
  # requirement Atlas does not impose — recorded so a candidate is never
  # rejected for lacking it.
  CHECKS = [
    [1, 'atomic directory rename', :directory_rename],
    [2, 'file rename over an existing file',     :file_rename_over],
    [3, 'read-after-write consistency',          :read_after_write],
    [4, 'fsync a file and a directory',          :fsync_support],
    [5, 'random read with seek',                 :random_read],
    [6, 'deep mkdir and directory enumeration',  :deep_mkdir_and_list],
    [7, 'no append or in-place modify needed',   nil],
    [8, 'the filenames the sanitiser emits',     :permissive_filenames]
  ].freeze

  # Names sanitize_filename can still produce after 0.6.146, so this checks the
  # substrate against the adapter's actual output domain rather than a guess.
  SANITISED_NAMES = [
    'plain.txt',
    'café.txt',
    'with space & ampersand (1).txt',
    '.hidden',
    "#{'x' * 196}.tif"
  ].freeze

  def initialize(path:)
    @path = Pathname.new(path)
  end

  def call
    raise ArgumentError, "not a directory: #{path}" unless path.directory?

    checks = measure
    { path: path.to_s, checks: checks, ok: checks.none? { |check| check.required && !check.ok } }
  end

  private

    attr_reader :path, :scratch

    def measure
      in_scratch_dir { CHECKS.map { |id, name, method| run_check(id, name, method) } }
    rescue SystemCallError => e
      # We cannot even make a working directory, so nothing else can be measured.
      # Report every requirement as unmet rather than raising: a read-only or
      # full mount is a real answer, and the tool should give a verdict for it.
      CHECKS.map { |id, name, method| unmet_check(id, name, method, e) }
    end

    def unmet_check(id, name, method, error)
      return Check.new(id: id, name: name, required: false, ok: true, detail: 'not required') if method.nil?

      Check.new(id: id, name: name, required: true, ok: false, detail: "#{error.class}: #{error.message}")
    end

    # Everything happens inside one uniquely named directory that we create and
    # remove, so a candidate holding real content is never touched.
    def in_scratch_dir
      @scratch = path.join(".substrate-check-#{SecureRandom.hex(6)}")
      FileUtils.mkdir_p(scratch)
      yield
    ensure
      FileUtils.rm_rf(scratch)
    end

    def run_check(id, name, method)
      return Check.new(id: id, name: name, required: false, ok: true, detail: 'not required') if method.nil?

      send(method)
      Check.new(id: id, name: name, required: true, ok: true)
    rescue StandardError, NotImplementedError => e
      Check.new(id: id, name: name, required: true, ok: false, detail: "#{e.class}: #{e.message}")
    end

    def fail!(message)
      raise NotImplementedError, message
    end

    # perform_upload stages a version directory and renames it into place. That
    # rename is the commit point, and Mountpoint for S3 refuses it outright.
    def directory_rename
      staged = scratch.join('staged')
      FileUtils.mkdir_p(staged.join('content'))
      ::File.write(staged.join('content', 'a.bin'), 'payload')

      ::File.rename(staged.to_s, scratch.join('v1').to_s)

      fail!('renamed directory is absent') unless scratch.join('v1', 'content', 'a.bin').exist?
      fail!('source directory survived the rename') if staged.exist?
    end

    # update_head_pointer replaces inventory.json by renaming a temporary over it.
    def file_rename_over
      target = scratch.join('head.json')
      ::File.write(target, 'old')
      ::File.write(scratch.join('head.tmp'), 'new')

      ::File.rename(scratch.join('head.tmp').to_s, target.to_s)

      fail!("rename-over left #{target.read.inspect}") unless target.read == 'new'
    end

    def read_after_write
      file = scratch.join('immediate.bin')
      ::File.write(file, 'now')
      fail!('a just-written file did not read back') unless ::File.read(file) == 'now'
    end

    # Mirrors what the adapter does after every write. A directory fsync is the
    # awkward one: some mounts reject it.
    def fsync_support
      file = scratch.join('durable.bin')
      ::File.open(file, 'wb') { |handle| handle.write('bytes') && handle.fsync }
      ::File.open(file.to_s, 'rb', &:fsync)
      ::File.open(scratch.to_s, &:fsync)
    end

    # HTTP Range on a Blob seeks into the content file rather than streaming it
    # from the start.
    def random_read
      file = scratch.join('seekable.bin')
      ::File.binwrite(file, (0..255).to_a.pack('C*'))

      slice = ::File.open(file, 'rb') { |handle| handle.seek(200) && handle.read(8) }

      fail!("seek returned #{slice.inspect}") unless slice == (200..207).to_a.pack('C*')
    end

    # The tuple layout nests objects, and the adapter lists a single object's
    # directory to find its highest version.
    def deep_mkdir_and_list
      nested = scratch.join('ab', 'cd', 'abcd1234e', 'v1', 'content')
      FileUtils.mkdir_p(nested)
      3.times { |i| ::File.write(nested.join("f#{i}.bin"), i.to_s) }

      listed = nested.children.map { |child| child.basename.to_s }.sort
      fail!("listed #{listed.inspect}") unless listed == %w[f0.bin f1.bin f2.bin]
    end

    def permissive_filenames
      SANITISED_NAMES.each do |name|
        file = scratch.join(name)
        ::File.write(file, name)
        fail!("#{name.inspect} did not read back") unless ::File.read(file) == name
      end

      missing = SANITISED_NAMES - scratch.children.map { |child| child.basename.to_s }
      fail!("absent after write: #{missing.inspect}") if missing.any?
    end
end
