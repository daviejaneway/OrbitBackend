if [ $# != 2 ]; then
	echo "usage: bump <commit_message> <tag>"
	exit 1
fi

git add .
git commit -m "$1"
git tag $2

git push
git push --tags