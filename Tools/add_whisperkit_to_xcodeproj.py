import sys
p=sys.argv[1]
s=open(p).read()
if 'argmax-oss-swift' in s:
    print('already'); sys.exit(0)
def rep(old,new):
    global s
    assert old in s, old
    s=s.replace(old,new,1)
rep('''		B10000000000000000000003 /* MLX in Frameworks */ = {isa = PBXBuildFile; productRef = B30000000000000000000003 /* MLX */; };''',
'''		B10000000000000000000003 /* MLX in Frameworks */ = {isa = PBXBuildFile; productRef = B30000000000000000000003 /* MLX */; };
		B10000000000000000000004 /* WhisperKit in Frameworks */ = {isa = PBXBuildFile; productRef = B30000000000000000000004 /* WhisperKit */; };''')
rep('''				B10000000000000000000003 /* MLX in Frameworks */,
			);''','''				B10000000000000000000003 /* MLX in Frameworks */,
				B10000000000000000000004 /* WhisperKit in Frameworks */,
			);''')
rep('''				B30000000000000000000003 /* MLX */,
			);''','''				B30000000000000000000003 /* MLX */,
				B30000000000000000000004 /* WhisperKit */,
			);''')
rep('''				B00000000000000000000002 /* XCRemoteSwiftPackageReference "mlx-swift" */,
			);''','''				B00000000000000000000002 /* XCRemoteSwiftPackageReference "mlx-swift" */,
				B00000000000000000000003 /* XCRemoteSwiftPackageReference "argmax-oss-swift" */,
			);''')
rep('''/* End XCRemoteSwiftPackageReference section */''','''		B00000000000000000000003 /* XCRemoteSwiftPackageReference "argmax-oss-swift" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/argmaxinc/argmax-oss-swift";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 1.1.1;
			};
		};
/* End XCRemoteSwiftPackageReference section */''')
rep('''/* End XCSwiftPackageProductDependency section */''','''		B30000000000000000000004 /* WhisperKit */ = {
			isa = XCSwiftPackageProductDependency;
			package = B00000000000000000000003 /* XCRemoteSwiftPackageReference "argmax-oss-swift" */;
			productName = WhisperKit;
		};
/* End XCSwiftPackageProductDependency section */''')
open(p,'w').write(s)
print('patched')
