fatpack:
	rm -rf local
	cpm install --target-perl 5.16
	fatpack-simple --cache ~/.perl-cpm/.fatpack-cache binary-install -o binary-install-tmp
	curl -fsSL https://raw.githubusercontent.com/skaji/perl-gzip-script/main/gzip-script.pl | perl - binary-install-tmp > ../binary-install
	rm -f binary-install-tmp
	chmod +x ../binary-install
