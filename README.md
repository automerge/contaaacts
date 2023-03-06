# Contaaacts

An example of using the automerge swift library to manage a shared address book

## Usage

```
# create a new address book
contaaacts create-addessbook ./friends

# Add a new contact
contaaacts add ./friends --name 'Alice' --email 'alice@example.com'

# List the contents of the address book
contaaacts list ./friends

# Modify a contact
contaaacts update ./friends alice --email 'alice2@example.com'

# merge with another version of the address book and output to a new file
contaaacts merge ./friends ./otherfriends ./merged

# provide a sync server for other peers to sync with on localhost:9090
contaaacts serve ./friends localhost 9090

# sync with a contaaacts server running at localhost:9090
contaaacts sync ./friends --server localhost 9090
```

