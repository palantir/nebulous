# nebulous
OpenNebula stuff for managing Jenkins and Bamboo agent pools

# Development
Just run `vagrant up` and you will get a ruby version for the vagrant user along with all the bundled gems in
/home/vagrant.

# Packaging
The packager directory also has a Vagrantfile that will compile ruby from source, put it in /opt, clone this repo,
bundle all the gems, move it to /opt, and finally package the whole thing as an RPM. Everything gets installed to
/opt. The ruby version is in /opt/ruby-2.2.2 and the code is in /opt/nebulous.

# Deployment
Make sure you have `~/.one/one_auth` and `~/.one/one_endpoint` containing username/password and XML-RPC endpoint
respectively. If you are using secure configuration then make sure you also have the public key for decrypting the
secure values. I usually put it in `~/.ssh/config.pub`. The rest of it is just a matter of making sure your
configurations and provisioners line up properly. You can keep everything in one repo or two. It doesn't really matter.
Just make sure they are accessible somewhere on the file system so that `lib/runner.rb` can read them.

Since there is a lot of ssh shelling out involved the assumption is that the public key of the user running
`lib/runner.rb` has their ssh key set up in OpenNebula so that root access with that key is possible. If this is not set
up then the VMs will come up but provisioning will fail.

As for the actual code just use `vagrant-packager` to generate an rpm and then install it with `rpm -i`.

# Configuration
Configuration is a very simple YAML file. Currently there are two types of configurations, jenkins and bamboo. The only
difference is really a few key-value pairs for username/password and maaster server endpoint.

## Bamboo
To configure a bamboo pool you just need to fill in the following template

```
name: 'hh'
type: 'bamboo'
count: 10
template_name: 'some template name'
provision:
- command: 'uptime'
type: 'inline'
- command: 'echo hi'
type: 'inline'
- command: 'touch i-was-here'
type: 'inline'
- path: '/root/provisioners/bamboo-hh.sh'
arguments: ['https://hh-bamboo-master', '${user}', '${password}']
type: 'script'
bamboo: 'https://hh-bamboo-master/'
bamboo_username: '${user}'
bamboo_password: '${password}'
```

Most of the above should be self-explanatory but here is the description of the keys just in case

* `name` - Name of the pool. The VMs in the pool will have a hash appended to the name just so the DNS entries end up being unique.
* `type` - Currently only `'bamboo'` or `'jenkins'`. So we know how to do registration with the master once the VM is ready.
* `count` - Number of VMs in the pool.
* `template_name`: Name of the template in OpenNebula that is used to instantiate the VMs.
* `provision` - List of provisioning stages. Currently supported types are `inline`, `script`, `directory`, `tar`. Look in `lib/stages.rb` for complete list.
* `bamboo` - IP address or HTTP(s) endpoint of master bamboo server.
* `bamboo_username` - Username of administrator account. We need this to scrape various endpoints for controlling agents.
* `bamboo_password` - The password for the administrator account.

Some values should remain secret and for those cases we use the travis-ci model of encrypting values with RSA keys and
using `secure: ${encrypted_value}` as the value. Unlike travis-ci the workflow is not automatic and you need to drop
into `irb` to do the encryption and Base64 encoding.

## Jenkins
Same as above with name changes for some of the keys

```
name: 'test'
type: 'jenkins'
count: 10
template_name: 'some template'
provision:
- type: "script"
path: "/root/provisioners/jenkins.sh"
arguments: []
jenkins: 'https://ivy/jenkins'
jenkins_username: '${user}'
jenkins_password: '${password}'
credentials_id: '2dfc58d2-9d2e-49dd-849b-4eb1a4933e54'
private_key_path: '${id_rsa}'
```

# Provisioner types
There are 4 types of provisioners currently and they all pretty much work the same way. Each provisioner is defined by a
path to a directory, a shell script, a tar file, or in the case of the inline provisioner just a string that will be
executed directly.

## Inline
Just define the type as `'inline'` and fill in the command:

```
type: 'inline'
command: 'uptime'
```

## Script
Define the type as `'script'` and fill in the path to the script and provide arguments if any:

```
type: 'script'
path: '/some/path/script.sh'
arguments:
- 'arg1'
- 'arg2'
- 'arg3'
```

## Directory
Define the type as `'directory'` and fill the path to the directory and the arguments as in the script type:

```
type: 'directory'
path: '/some/directory'
arguments:
- 'arg1'
- 'arg2'
- 'arg3'
```

You might be wondering how a directory is executed, well it's not. The assumption is that the directory has a shell
script called `setup.sh` that will be executed and the arguments are passed to that shell script. The actual operational
semantics is to scp the directory to the VM, cd into the directory, and finally run `setup.sh` with the given arguments.

## Tar
Define the type as `'tar'` and fill in the path and arguments as above. The operational semantics is the same as for the
directory except there is one extra step where the tar file is untarred. The assumption is that there is `setup.sh` that
will do the work.

```
type: 'tar'
path: '/some/path/bundle.tar'
arguments:
- 'arg1'
- 'arg2'
- 'arg3'
```

# Secure Values
This was shamelessly stolen from how the travis cli does things. You need an RSA key pair. Use one to encrypt and the
other to decrypt. Since we are not sending messages to third parties and this is all meant for internal use it doesn't
really matter which key you use to encrypt or decrypt. Since the public key can be derived from the private key but not
vice-versa I use the private key to encrypt and the public key to decrypt so only the public key needs to be on the node
where nebulous is running.

## Encrypting Values
No utility yet just a snippet of IRB code

```ruby
require 'openssl'
require 'base64'
key = OpenSSL::RSA::PKey.new(private_key)
encrypted_value = Base64.encode64(key.private_encrypt(value)).gsub("\n", '')
```

## Decrypting Values
Pretty much same as above but you pass in the public key and base64 decode the encrypted value before passing it in.
This is what happens when the configuration is loaded so this snippet is just for making sure you performed the
encryption properly

```ruby
require 'openssl'
require 'base64'
key = OpenSSL::RSA::PKey.new(public_key)
decrypted_value = key.public_decrypt(Base.decode64(base64_encrypted_value))
```
