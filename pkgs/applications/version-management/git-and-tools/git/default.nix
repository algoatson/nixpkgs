{ fetchurl, lib, stdenv, buildPackages
, curl, openssl, zlib, expat, perlPackages, python3, gettext, cpio
, gnugrep, gnused, gawk, coreutils # needed at runtime by git-filter-branch etc
, openssh, pcre2
, asciidoc, texinfo, xmlto, docbook2x, docbook_xsl, docbook_xml_dtd_45
, libxslt, tcl, tk, makeWrapper, libiconv
, svnSupport, subversionClient, perlLibs, smtpPerlLibs
, perlSupport ? stdenv.buildPlatform == stdenv.hostPlatform
, nlsSupport ? true
, osxkeychainSupport ? stdenv.isDarwin
, guiSupport
, withManual ? true
, pythonSupport ? true
, withpcre2 ? true
, sendEmailSupport
, darwin
, nixosTests
, withLibsecret ? false
, pkg-config, glib, libsecret
, gzip # needed at runtime by gitweb.cgi
}:

assert osxkeychainSupport -> stdenv.isDarwin;
assert sendEmailSupport -> perlSupport;
assert svnSupport -> perlSupport;

let
  version = "2.33.1";
  svn = subversionClient.override { perlBindings = perlSupport; };

  gitwebPerlLibs = with perlPackages; [ CGI HTMLParser CGIFast FCGI FCGIProcManager HTMLTagCloud ];
in

stdenv.mkDerivation {
  pname = "git";
  inherit version;

  src = fetchurl {
    url = "https://www.kernel.org/pub/software/scm/git/git-${version}.tar.xz";
    sha256 = "sha256-4FSm5sKwiL0b/19h7ZulqpHJo81QlTmktBxd3wIgHy8=";
  };

  outputs = [ "out" ] ++ lib.optional withManual "doc";

  hardeningDisable = [ "format" ];

  enableParallelBuilding = true;

  ## Patch

  patches = [
    ./docbook2texi.patch
    ./git-sh-i18n.patch
    ./ssh-path.patch
    ./git-send-email-honor-PATH.patch
    ./installCheck-path.patch
  ];

  postPatch = ''
    for x in connect.c git-gui/lib/remote_add.tcl ; do
      substituteInPlace "$x" \
        --subst-var-by ssh "${openssh}/bin/ssh"
    done

    # Fix references to gettext introduced by ./git-sh-i18n.patch
    substituteInPlace git-sh-i18n.sh \
        --subst-var-by gettext ${gettext}

    # ensure we are using the correct shell when executing the test scripts
    patchShebangs t/*.sh
  '';

  nativeBuildInputs = [ gettext perlPackages.perl makeWrapper ]
    ++ lib.optionals withManual [ asciidoc texinfo xmlto docbook2x
         docbook_xsl docbook_xml_dtd_45 libxslt ];
  buildInputs = [curl openssl zlib expat cpio libiconv]
    ++ lib.optionals perlSupport [ perlPackages.perl ]
    ++ lib.optionals guiSupport [tcl tk]
    ++ lib.optionals withpcre2 [ pcre2 ]
    ++ lib.optionals stdenv.isDarwin [ darwin.Security ]
    ++ lib.optionals withLibsecret [ pkg-config glib libsecret ];

  # required to support pthread_cancel()
  NIX_LDFLAGS = lib.optionalString (stdenv.cc.isGNU && stdenv.hostPlatform.libc == "glibc") "-lgcc_s"
              + lib.optionalString (stdenv.isFreeBSD) "-lthr";

  configureFlags = lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
    "ac_cv_fread_reads_directories=yes"
    "ac_cv_snprintf_returns_bogus=no"
    "ac_cv_iconv_omits_bom=no"
    "ac_cv_prog_CURL_CONFIG=${curl.dev}/bin/curl-config"
  ];

  preBuild = ''
    makeFlagsArray+=( perllibdir=$out/$(perl -MConfig -wle 'print substr $Config{installsitelib}, 1 + length $Config{siteprefixexp}') )
  '';

  makeFlags = [
    "prefix=\${out}"
  ]
  # Git does not allow setting a shell separately for building and run-time.
  # Therefore lets leave it at the default /bin/sh when cross-compiling
  ++ lib.optional (stdenv.buildPlatform == stdenv.hostPlatform) "SHELL_PATH=${stdenv.shell}"
  ++ (if perlSupport then ["PERL_PATH=${perlPackages.perl}/bin/perl"] else ["NO_PERL=1"])
  ++ (if pythonSupport then ["PYTHON_PATH=${python3}/bin/python"] else ["NO_PYTHON=1"])
  ++ lib.optionals stdenv.isSunOS ["INSTALL=install" "NO_INET_NTOP=" "NO_INET_PTON="]
  ++ (if stdenv.isDarwin then ["NO_APPLE_COMMON_CRYPTO=1"] else ["sysconfdir=/etc"])
  ++ lib.optionals stdenv.hostPlatform.isMusl ["NO_SYS_POLL_H=1" "NO_GETTEXT=YesPlease"]
  ++ lib.optional withpcre2 "USE_LIBPCRE2=1"
  ++ lib.optional (!nlsSupport) "NO_GETTEXT=1"
  # git-gui refuses to start with the version of tk distributed with
  # macOS Catalina. We can prevent git from building the .app bundle
  # by specifying an invalid tk framework. The postInstall step will
  # then ensure that git-gui uses tcl/tk from nixpkgs, which is an
  # acceptable version.
  #
  # See https://github.com/Homebrew/homebrew-core/commit/dfa3ccf1e7d3901e371b5140b935839ba9d8b706
  ++ lib.optional stdenv.isDarwin "TKFRAMEWORK=/nonexistent";

  disallowedReferences = lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
    stdenv.shellPackage
  ];


  postBuild = ''
    make -C contrib/subtree
  '' + (lib.optionalString perlSupport ''
    make -C contrib/diff-highlight
  '') + (lib.optionalString osxkeychainSupport ''
    make -C contrib/credential/osxkeychain
  '') + (lib.optionalString withLibsecret ''
    make -C contrib/credential/libsecret
  '');


  ## Install

  # WARNING: Do not `rm` or `mv` files from the source tree; use `cp` instead.
  #          We need many of these files during the installCheckPhase.

  installFlags = [ "NO_INSTALL_HARDLINKS=1" ];

  preInstall = (lib.optionalString osxkeychainSupport ''
    mkdir -p $out/bin
    ln -s $out/share/git/contrib/credential/osxkeychain/git-credential-osxkeychain $out/bin/
    rm -f $PWD/contrib/credential/osxkeychain/git-credential-osxkeychain.o
  '') + (lib.optionalString withLibsecret ''
    mkdir -p $out/bin
    ln -s $out/share/git/contrib/credential/libsecret/git-credential-libsecret $out/bin/
    rm -f $PWD/contrib/credential/libsecret/git-credential-libsecret.o
  '');

  postInstall =
    ''
      notSupported() {
        unlink $1 || true
      }

      # Install git-subtree.
      make -C contrib/subtree install ${lib.optionalString withManual "install-doc"}
      rm -rf contrib/subtree

      # Install contrib stuff.
      mkdir -p $out/share/git
      cp -a contrib $out/share/git/
      mkdir -p $out/share/bash-completion/completions
      ln -s $out/share/git/contrib/completion/git-completion.bash $out/share/bash-completion/completions/git
      mkdir -p $out/share/bash-completion/completions
      ln -s $out/share/git/contrib/completion/git-prompt.sh $out/share/bash-completion/completions/

      # grep is a runtime dependency, need to patch so that it's found
      substituteInPlace $out/libexec/git-core/git-sh-setup \
          --replace ' grep' ' ${gnugrep}/bin/grep' \
          --replace ' egrep' ' ${gnugrep}/bin/egrep'

      # Fix references to the perl, sed, awk and various coreutil binaries used by
      # shell scripts that git calls (e.g. filter-branch)
      SCRIPT="$(cat <<'EOS'
        BEGIN{
          @a=(
            '${gnugrep}/bin/grep', '${gnused}/bin/sed', '${gawk}/bin/awk',
            '${coreutils}/bin/cut', '${coreutils}/bin/basename', '${coreutils}/bin/dirname',
            '${coreutils}/bin/wc', '${coreutils}/bin/tr'
            ${lib.optionalString perlSupport ", '${perlPackages.perl}/bin/perl'"}
          );
        }
        foreach $c (@a) {
          $n=(split("/", $c))[-1];
          s|(?<=[^#][^/.-])\b''${n}(?=\s)|''${c}|g
        }
      EOS
      )"
      perl -0777 -i -pe "$SCRIPT" \
        $out/libexec/git-core/git-{sh-setup,filter-branch,merge-octopus,mergetool,quiltimport,request-pull,submodule,subtree,web--browse}


      # Also put git-http-backend into $PATH, so that we can use smart
      # HTTP(s) transports for pushing
      ln -s $out/libexec/git-core/git-http-backend $out/bin/git-http-backend
    '' + lib.optionalString perlSupport ''
      # wrap perl commands
      makeWrapper "$out/share/git/contrib/credential/netrc/git-credential-netrc.perl" $out/bin/git-credential-netrc \
                  --set PERL5LIB   "$out/${perlPackages.perl.libPrefix}:${perlPackages.makePerlPath perlLibs}"
      wrapProgram $out/libexec/git-core/git-cvsimport \
                  --set GITPERLLIB "$out/${perlPackages.perl.libPrefix}:${perlPackages.makePerlPath perlLibs}"
      wrapProgram $out/libexec/git-core/git-add--interactive \
                  --set GITPERLLIB "$out/${perlPackages.perl.libPrefix}:${perlPackages.makePerlPath perlLibs}"
      wrapProgram $out/libexec/git-core/git-archimport \
                  --set GITPERLLIB "$out/${perlPackages.perl.libPrefix}:${perlPackages.makePerlPath perlLibs}"
      wrapProgram $out/libexec/git-core/git-instaweb \
                  --set GITPERLLIB "$out/${perlPackages.perl.libPrefix}:${perlPackages.makePerlPath perlLibs}"
      wrapProgram $out/libexec/git-core/git-cvsexportcommit \
                  --set GITPERLLIB "$out/${perlPackages.perl.libPrefix}:${perlPackages.makePerlPath perlLibs}"

      # gzip (and optionally bzip2, xz, zip) are runtime dependencies for
      # gitweb.cgi, need to patch so that it's found
      sed -i -e "s|'compressor' => \['gzip'|'compressor' => ['${gzip}/bin/gzip'|" \
          $out/share/gitweb/gitweb.cgi
      # Give access to CGI.pm and friends (was removed from perl core in 5.22)
      for p in ${lib.concatStringsSep " " gitwebPerlLibs}; do
          sed -i -e "/use CGI /i use lib \"$p/${perlPackages.perl.libPrefix}\";" \
              "$out/share/gitweb/gitweb.cgi"
      done
    ''

   + (if svnSupport then ''
        # wrap git-svn
        wrapProgram $out/libexec/git-core/git-svn                                                                                \
                     --set GITPERLLIB "$out/${perlPackages.perl.libPrefix}:${perlPackages.makePerlPath (perlLibs ++ [svn.out])}" \
                     --prefix PATH : "${svn.out}/bin" ''
       else '' # replace git-svn by notification script
        notSupported $out/libexec/git-core/git-svn
     '')

   + (if sendEmailSupport then ''
        # wrap git-send-email
        wrapProgram $out/libexec/git-core/git-send-email \
                     --set GITPERLLIB "$out/${perlPackages.perl.libPrefix}:${perlPackages.makePerlPath smtpPerlLibs}"
      '' else ''
        # replace git-send-email by notification script
        notSupported $out/libexec/git-core/git-send-email
      '')

   + lib.optionalString withManual ''# Install man pages
       make -j $NIX_BUILD_CORES -l $NIX_BUILD_CORES PERL_PATH="${buildPackages.perl}/bin/perl" cmd-list.made install install-html \
         -C Documentation ''

   + (if guiSupport then ''
       # Wrap Tcl/Tk programs
       for prog in bin/gitk libexec/git-core/{git-gui,git-citool,git-gui--askpass}; do
         sed -i -e "s|exec 'wish'|exec '${tk}/bin/wish'|g" \
                -e "s|exec wish|exec '${tk}/bin/wish'|g" \
                "$out/$prog"
       done
       ln -s $out/share/git/contrib/completion/git-completion.bash $out/share/bash-completion/completions/gitk
     '' else ''
       # Don't wrap Tcl/Tk, replace them by notification scripts
       for prog in bin/gitk libexec/git-core/git-gui; do
         notSupported "$out/$prog"
       done
     '')
   + lib.optionalString osxkeychainSupport ''
    # enable git-credential-osxkeychain on darwin if desired (default)
    mkdir -p $out/etc
    cat > $out/etc/gitconfig << EOF
    [credential]
      helper = osxkeychain
    EOF
  '';


  ## InstallCheck

  doCheck = false;
  doInstallCheck = true;

  installCheckTarget = "test";

  # see also installCheckFlagsArray
  installCheckFlags = [
    "DEFAULT_TEST_TARGET=prove"
    "PERL_PATH=${buildPackages.perl}/bin/perl"
  ];

  preInstallCheck = ''
    installCheckFlagsArray+=(
      GIT_PROVE_OPTS="--jobs $NIX_BUILD_CORES --failures --state=failed,save"
      GIT_TEST_INSTALLED=$out/bin
      ${lib.optionalString (!svnSupport) "NO_SVN_TESTS=y"}
    )

    function disable_test {
      local test=$1 pattern=$2
      if [ $# -eq 1 ]; then
        mv t/{,skip-}$test.sh || true
      else
        sed -i t/$test.sh \
          -e "/^\s*test_expect_.*$pattern/,/^\s*' *\$/{s/^/: #/}"
      fi
    }

    # Shared permissions are forbidden in sandbox builds:
    substituteInPlace t/test-lib.sh \
      --replace "test_set_prereq POSIXPERM" ""
    # TODO: Investigate while these still fail (without POSIXPERM):
    disable_test t0001-init 'shared overrides system'
    disable_test t0001-init 'init honors global core.sharedRepository'
    disable_test t1301-shared-repo
    # git-completion.bash: line 405: compgen: command not found:
    disable_test t9902-completion 'option aliases are shown with GIT_COMPLETION_SHOW_ALL'

    # Our patched gettext never fallbacks
    disable_test t0201-gettext-fallbacks

    ${lib.optionalString (!sendEmailSupport) ''
      # Disable sendmail tests
      disable_test t9001-send-email
    ''}

    # XXX: I failed to understand why this one fails.
    # Could someone try to re-enable it on the next release ?
    # Tested to fail: 2.18.0 and 2.19.0
    disable_test t1700-split-index "null sha1"

    # Tested to fail: 2.18.0
    disable_test t9902-completion "sourcing the completion script clears cached --options"

    # Flaky tests:
    disable_test t5319-multi-pack-index
    disable_test t6421-merge-partial-clone

    ${lib.optionalString (!perlSupport) ''
      # request-pull is a Bash script that invokes Perl, so it is not available
      # when NO_PERL=1, and the test should be skipped, but the test suite does
      # not check for the Perl prerequisite.
      disable_test t5150-request-pull
    ''}
  '' + lib.optionalString stdenv.isDarwin ''
    # XXX: Some tests added in 2.24.0 fail.
    # Please try to re-enable on the next release.
    disable_test t7816-grep-binary-pattern
    # fail (as of 2.33.0)
    #===(   18623;1208  8/?  224/?  2/? )= =fatal: Not a valid object name refs/tags/signed-empty
    disable_test t6300-for-each-ref
    #===(   22665;1651  9/?  1/?  0/?  0/? )= =/private/tmp/nix-build-git-2.33.0.drv-2/git-2.33.0/t/../contrib/completion/git-completion.bash: line 405: compgen: command not found
    disable_test t9902-completion
    # not ok 1 - populate workdir (with 2.33.1 on x86_64-darwin)
    disable_test t5003-archive-zip
  '' + lib.optionalString stdenv.hostPlatform.isMusl ''
    # Test fails (as of 2.17.0, musl 1.1.19)
    disable_test t3900-i18n-commit
    # Fails largely due to assumptions about BOM
    # Tested to fail: 2.18.0
    disable_test t0028-working-tree-encoding
  '';

  stripDebugList = [ "lib" "libexec" "bin" "share/git/contrib/credential/libsecret" ];

  passthru = {
    shellPath = "/bin/git-shell";
    tests = {
      buildbot-integration = nixosTests.buildbot;
    };
  };

  meta = {
    homepage = "https://git-scm.com/";
    description = "Distributed version control system";
    license = lib.licenses.gpl2;
    changelog = "https://github.com/git/git/blob/v${version}/Documentation/RelNotes/${version}.txt";

    longDescription = ''
      Git, a popular distributed version control system designed to
      handle very large projects with speed and efficiency.
    '';

    platforms = lib.platforms.all;
    maintainers = with lib.maintainers; [ primeos wmertens globin ];
  };
}
