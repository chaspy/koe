### Windows
- Fixed: a recording finished just before midnight could fail to save to history, because the daily cleanup could remove its still-empty day folder at the same moment. The cleanup now never removes today's or yesterday's folder, and saving recreates the folder if it is gone.
