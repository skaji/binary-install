fatpack:
	rm -rf local
	cpm install --target-perl 5.16
	fatpack-simple --cache ~/.perl-cpm/.fatpack-cache binary-install -o ../binary-install
	perl-gzip-script -i ../binary-install
	chmod +x ../binary-install
	perl-cpan-index-generate local > index.txt
