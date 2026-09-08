# frozen_string_literal: true

# MARC relator code -> the role label a reader sees. MODS lets a name give its
# role as a code (`<roleTerm type="code" authority="marcrelator">aut</>`), and
# neu-mods projects that code raw and deliberately: the code is what the record
# says, and the *label* for it is display vocabulary, which differs per consumer
# -- Cerberus's edit form words a role differently from Atlas's display. So the
# table lives here rather than in the gem.
#
# Vendored from the Library of Congress MARC relator list (the same table
# sul-dlss/mods_display carries), so there is no new dependency and no code
# renders as a three-letter label. An unlisted code falls back to itself.
module MarcRelators
  TERMS = {
    'abr' => 'Abridger',
    'acp' => 'Art copyist',
    'act' => 'Actor',
    'adi' => 'Art director',
    'adp' => 'Adapter',
    'aft' => 'Author of afterword, colophon, etc.',
    'anl' => 'Analyst',
    'anm' => 'Animator',
    'ann' => 'Annotator',
    'ant' => 'Bibliographic antecedent',
    'ape' => 'Appellee',
    'apl' => 'Appellant',
    'app' => 'Applicant',
    'aqt' => 'Author in quotations or text abstracts',
    'arc' => 'Architect',
    'ard' => 'Artistic director',
    'arr' => 'Arranger',
    'art' => 'Artist',
    'asg' => 'Assignee',
    'asn' => 'Associated name',
    'ato' => 'Autographer',
    'att' => 'Attributed name',
    'auc' => 'Auctioneer',
    'aud' => 'Author of dialog',
    'aui' => 'Author of introduction, etc.',
    'aus' => 'Screenwriter',
    'aut' => 'Author',
    'bdd' => 'Binding designer',
    'bjd' => 'Bookjacket designer',
    'bkd' => 'Book designer',
    'bkp' => 'Book producer',
    'blw' => 'Blurb writer',
    'bnd' => 'Binder',
    'bpd' => 'Bookplate designer',
    'brd' => 'Broadcaster',
    'brl' => 'Braille embosser',
    'bsl' => 'Bookseller',
    'cas' => 'Caster',
    'ccp' => 'Conceptor',
    'chr' => 'Choreographer',
    'clb' => 'Collaborator',
    'cli' => 'Client',
    'cll' => 'Calligrapher',
    'clr' => 'Colorist',
    'clt' => 'Collotyper',
    'cmm' => 'Commentator',
    'cmp' => 'Composer',
    'cmt' => 'Compositor',
    'cnd' => 'Conductor',
    'cng' => 'Cinematographer',
    'cns' => 'Censor',
    'coe' => 'Contestant-appellee',
    'col' => 'Collector',
    'com' => 'Compiler',
    'con' => 'Conservator',
    'cor' => 'Collection registrar',
    'cos' => 'Contestant',
    'cot' => 'Contestant-appellant',
    'cou' => 'Court governed',
    'cov' => 'Cover designer',
    'cpc' => 'Copyright claimant',
    'cpe' => 'Complainant-appellee',
    'cph' => 'Copyright holder',
    'cpl' => 'Complainant',
    'cpt' => 'Complainant-appellant',
    'cre' => 'Creator',
    'crp' => 'Correspondent',
    'crr' => 'Corrector',
    'crt' => 'Court reporter',
    'csl' => 'Consultant',
    'csp' => 'Consultant to a project',
    'cst' => 'Costume designer',
    'ctb' => 'Contributor',
    'cte' => 'Contestee-appellee',
    'ctg' => 'Cartographer',
    'ctr' => 'Contractor',
    'cts' => 'Contestee',
    'ctt' => 'Contestee-appellant',
    'cur' => 'Curator',
    'cwt' => 'Commentator for written text',
    'dbp' => 'Distribution place',
    'dfd' => 'Defendant',
    'dfe' => 'Defendant-appellee',
    'dft' => 'Defendant-appellant',
    'dgg' => 'Degree granting institution',
    'dis' => 'Dissertant',
    'dln' => 'Delineator',
    'dnc' => 'Dancer',
    'dnr' => 'Donor',
    'dpc' => 'Depicted',
    'dpt' => 'Depositor',
    'drm' => 'Draftsman',
    'drt' => 'Director',
    'dsr' => 'Designer',
    'dst' => 'Distributor',
    'dtc' => 'Data contributor',
    'dte' => 'Dedicatee',
    'dtm' => 'Data manager',
    'dto' => 'Dedicator',
    'dub' => 'Dubious author',
    'edc' => 'Editor of compilation',
    'edm' => 'Editor of moving image work',
    'edt' => 'Editor',
    'egr' => 'Engraver',
    'elg' => 'Electrician',
    'elt' => 'Electrotyper',
    'eng' => 'Engineer',
    'enj' => 'Enacting jurisdiction',
    'etr' => 'Etcher',
    'evp' => 'Event place',
    'exp' => 'Expert',
    'fac' => 'Facsimilist',
    'fds' => 'Film distributor',
    'fld' => 'Field director',
    'flm' => 'Film editor',
    'fmd' => 'Film director',
    'fmk' => 'Filmmaker',
    'fmo' => 'Former owner',
    'fmp' => 'Film producer',
    'fnd' => 'Funder',
    'fpy' => 'First party',
    'frg' => 'Forger',
    'gis' => 'Geographic information specialist',
    'grt' => 'Graphic technician',
    'his' => 'Host institution',
    'hnr' => 'Honoree',
    'hst' => 'Host',
    'ill' => 'Illustrator',
    'ilu' => 'Illuminator',
    'ins' => 'Inscriber',
    'itr' => 'Instrumentalist',
    'ive' => 'Interviewee',
    'ivr' => 'Interviewer',
    'inv' => 'Inventor',
    'isb' => 'Issuing body',
    'jud' => 'Judge',
    'jug' => 'Jurisdiction governed',
    'lbr' => 'Laboratory',
    'lbt' => 'Librettist',
    'ldr' => 'Laboratory director',
    'led' => 'Lead',
    'lee' => 'Libelee-appellee',
    'lel' => 'Libelee',
    'len' => 'Lender',
    'let' => 'Libelee-appellant',
    'lgd' => 'Lighting designer',
    'lie' => 'Libelant-appellee',
    'lil' => 'Libelant',
    'lit' => 'Libelant-appellant',
    'lsa' => 'Landscape architect',
    'lse' => 'Licensee',
    'lso' => 'Licensor',
    'ltg' => 'Lithographer',
    'lyr' => 'Lyricist',
    'mcp' => 'Music copyist',
    'mdc' => 'Metadata contact',
    'mfp' => 'Manufacture place',
    'mfr' => 'Manufacturer',
    'mod' => 'Moderator',
    'mon' => 'Monitor',
    'mrb' => 'Marbler',
    'mrk' => 'Markup editor',
    'msd' => 'Musical director',
    'mte' => 'Metal-engraver',
    'mus' => 'Musician',
    'nrt' => 'Narrator',
    'opn' => 'Opponent',
    'org' => 'Originator',
    'orm' => 'Organizer of meeting',
    'osp' => 'Onscreen presenter',
    'oth' => 'Other',
    'own' => 'Owner',
    'pan' => 'Panelist',
    'pat' => 'Patron',
    'pbd' => 'Publishing director',
    'pbl' => 'Publisher',
    'pdr' => 'Project director',
    'pfr' => 'Proofreader',
    'pht' => 'Photographer',
    'plt' => 'Platemaker',
    'pma' => 'Permitting agency',
    'pmn' => 'Production manager',
    'pop' => 'Printer of plates',
    'ppm' => 'Papermaker',
    'ppt' => 'Puppeteer',
    'pra' => 'Praeses',
    'prc' => 'Process contact',
    'prd' => 'Production personnel',
    'pre' => 'Presenter',
    'prf' => 'Performer',
    'prg' => 'Programmer',
    'prm' => 'Printmaker',
    'prn' => 'Production company',
    'pro' => 'Producer',
    'prp' => 'Production place',
    'prs' => 'Production designer',
    'prt' => 'Printer',
    'prv' => 'Provider',
    'pta' => 'Patent applicant',
    'pte' => 'Plaintiff-appellee',
    'ptf' => 'Plaintiff',
    'pth' => 'Patent holder',
    'ptt' => 'Plaintiff-appellant',
    'pup' => 'Publication place',
    'rbr' => 'Rubricator',
    'rce' => 'Recording engineer',
    'rcd' => 'Recordist',
    'rcp' => 'Addressee',
    'rdd' => 'Radio director',
    'red' => 'Redaktor',
    'ren' => 'Renderer',
    'res' => 'Researcher',
    'rev' => 'Reviewer',
    'rpc' => 'Radio producer',
    'rps' => 'Repository',
    'rpt' => 'Reporter',
    'rpy' => 'Responsible party',
    'rse' => 'Respondent-appellee',
    'rsg' => 'Restager',
    'rsp' => 'Respondent',
    'rsr' => 'Restorationist',
    'rst' => 'Respondent-appellant',
    'rth' => 'Research team head',
    'rtm' => 'Research team member',
    'sad' => 'Scientific advisor',
    'sce' => 'Scenarist',
    'scl' => 'Sculptor',
    'scr' => 'Scribe',
    'sds' => 'Sound designer',
    'sec' => 'Secretary',
    'sgd' => 'Stage director',
    'sgn' => 'Signer',
    'sht' => 'Supporting host',
    'sll' => 'Seller',
    'sng' => 'Singer',
    'spk' => 'Speaker',
    'spn' => 'Sponsor',
    'spy' => 'Second party',
    'std' => 'Set designer',
    'stg' => 'Setting',
    'stl' => 'Storyteller',
    'stm' => 'Stage manager',
    'stn' => 'Standards body',
    'str' => 'Stereotyper',
    'srv' => 'Surveyor',
    'tcd' => 'Technical director',
    'tch' => 'Teacher',
    'ths' => 'Thesis advisor',
    'tld' => 'Television director',
    'tlp' => 'Television producer',
    'trc' => 'Transcriber',
    'trl' => 'Translator',
    'tyd' => 'Type designer',
    'tyg' => 'Typographer',
    'uvp' => 'University place',
    'vdg' => 'Videographer',
    'voc' => 'Vocalist',
    'wac' => 'Writer of added commentary',
    'wal' => 'Writer of added lyrics',
    'wam' => 'Writer of accompanying material',
    'wat' => 'Writer of added text',
    'wdc' => 'Woodcutter',
    'wde' => 'Wood engraver',
    'wit' => 'Witness'
  }.freeze

  # Roles that mean "made this thing", after code translation. A record in the
  # corpus writes Creator; a machine-generated one writes the MARC code aut,
  # which reads Author. They are the same person to a citation, a creator facet
  # and dc:creator -- a Contributor is not.
  # Compared case-insensitively: a text roleTerm is free text, the corpus holds
  # both "Creator" and "creator", and only the codes go through the table.
  CREATOR_LABELS = %w[Creator Author].freeze

  # The shape of a MARC relator code: exactly three ASCII letters. It is the
  # only thing separating an unlisted CODE from a free-text roleTerm, because
  # neu-mods projects the text term in preference to the code and does not say
  # which it gave. "Photographer" is a role a cataloguer wrote and must survive
  # as itself; "zzz" is a typo and must not become a display heading.
  RELATOR_CODE = /\A[a-z]{3}\z/

  # Whether the role is code-shaped and absent from the table. A caller that
  # renders the label decides what to put in its place; #label keeps falling
  # through to the role itself, because .creator? reads the same value and an
  # unlisted code is still not a creator.
  def self.unknown_code?(role)
    key = role.to_s.strip.downcase
    RELATOR_CODE.match?(key) && !TERMS.key?(key)
  end

  # The authorised labels, keyed by the label itself downcased, so a text
  # roleTerm can reach the same entry its code does. Built from TERMS rather
  # than listed, because a second copy of a 300-row vocabulary drifts.
  LABELS_BY_NAME = TERMS.values.index_by(&:downcase).freeze

  # The label for a role, which may be a code ("aut"), a text term ("author"),
  # or nil. Returns nil for a blank role so the caller can apply its own
  # default -- an absent role is not the same as an unrecognised one.
  #
  # A text term is matched against the vocabulary by NAME. Passed through as
  # typed, "author" and "aut" are the same claim under two headings, so one
  # capital letter decided whether two names grouped into one row or split into
  # two -- and the lowercase one read as a rendering fault beside "Publisher".
  #
  # A term the vocabulary does not hold survives exactly as written. This
  # normalises only where an authorised form already exists to normalise to;
  # "Wrangler" is what the cataloguer meant and there is nothing to match it
  # against.
  def self.label(role)
    key = role.to_s.strip
    return nil if key.empty?

    TERMS[key.downcase] || LABELS_BY_NAME.fetch(key.downcase, key)
  end

  # Whether a role marks its name as a creator of the resource.
  #
  # Matching the literal string "creator" excluded `aut` and `Author`, which
  # are the same claim written differently, so a record using either was
  # missing from the creator facet and harvested as dc:contributor.
  #
  # An absent role counts as a creator. MODS makes mods:role optional, the
  # display already labels a role-less name Creator, and mods_display treats an
  # empty role the same way -- so this is where the rest of the system already
  # was, rather than a new claim about those records.
  def self.creator?(role)
    term = label(role)
    term.nil? || CREATOR_LABELS.any? { |candidate| candidate.casecmp?(term) }
  end
end
