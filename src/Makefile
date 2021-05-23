fatpack:
	rm -rf local
	cpm install --target-perl 5.8.1
	fatpack-simple --cache ~/.perl-cpm/.fatpack-cache -e Test::More,Carp binary-install -o ../binary-install
	chmod +x ../binary-install
