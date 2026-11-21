"""ROVLOC name bank list (written by the voice engineer, round 4): common first names a school register would have,
plain ASCII, boys and girls. Left out on purpose: Danny, Kayla, Marcus (players with those names always get the twin,
monster-lines.md 3), Michael and Walter (banned words, monster-lines.md rule 4), Gus (the janitor)."""
BOYS = """James John Robert David William Richard Joseph Thomas Charles Christopher Daniel Matthew Anthony Mark Steven
Paul Andrew Joshua Kevin Brian George Timothy Ryan Jacob Nicholas Eric Jonathan Justin Brandon Benjamin Samuel
Alexander Patrick Jack Tyler Aaron Jose Adam Nathan Henry Zachary Peter Kyle Noah Ethan Jeremy Christian Sean Austin
Carlos Dylan Jordan Logan Luke Liam Mason Elijah Oliver Lucas Aiden Jackson Sebastian Caleb Owen Wyatt Gabriel Isaac
Levi Julian Hunter Connor Eli Landon Adrian Cameron Evan Nolan Hudson Carter Isaiah Josiah Chase Cooper Parker Miles
Max Leo Ezra Asher Luis Diego Juan Miguel Antonio Mateo Ian Cole Blake Jason Alex Sam Ben Nick Jake Theo Finn Jayden
Xavier Dominic Vincent Omar Ali Malik Darius Andre Jamal Tristan Trevor Derek Travis Wesley Bryce Spencer Jesse Kai
Silas Declan Emmett Roman Jasper Felix Ivan Victor Oscar Rafael Mohammed Ahmed Hassan Raj Arjun Kenji Tommy Bobby
Charlie Joey Frank Gavin Brody Colin Shane Grant""".split()
GIRLS = """Mary Elizabeth Jennifer Sarah Jessica Emily Ashley Amanda Megan Lauren Rachel Hannah Samantha Nicole Stephanie
Rebecca Laura Michelle Amy Anna Emma Olivia Ava Sophia Isabella Mia Charlotte Amelia Harper Evelyn Abigail Ella Avery
Scarlett Madison Lily Chloe Grace Zoey Nora Layla Aria Ellie Stella Natalie Leah Hazel Violet Aurora Savannah Audrey
Brooklyn Bella Claire Skylar Lucy Caroline Kennedy Maya Willow Naomi Aaliyah Elena Ariana Allison Gabriella Alice Ruby
Eva Autumn Hailey Isla Quinn Ivy Sadie Piper Lydia Alexa Josephine Julia Vivian Sophie Madeline Peyton Clara Melanie
Mackenzie Jade Katherine Isabelle Maria Taylor Faith Rose Kylie Alexandra Brianna Bailey Andrea Jasmine Iris Molly
Reese Morgan Sydney Daisy Kimberly Diana Summer Brooke Paige Fiona Georgia Tessa Hope Ruth Kate Maggie Jane Nina Phoebe
Talia Priya Aisha Fatima Mei Yasmin Carmen Lucia Gianna Valentina Camila Sofia Alyssa Destiny Jada Imani Kiara Erin
Kelsey Jenna Haley Danielle Courtney Heather Katie Lindsay Holly Amber Chelsea Sierra""".split()
EXCLUDE = {"Danny", "Kayla", "Marcus", "Michael", "Walter", "Gus"}
def bank(n_each=125):
    seen, out = set(), []
    for lst, g in ((BOYS, "boy"), (GIRLS, "girl")):
        k = 0
        for n in lst:
            if n in seen or n in EXCLUDE:
                continue
            assert n.isascii() and n.isalpha(), n
            seen.add(n); out.append((n, g)); k += 1
            if k == n_each:
                break
    return out
if __name__ == "__main__":
    b = bank(); print(len(b), sum(g == "boy" for _, g in b), sum(g == "girl" for _, g in b))
    print(len(BOYS), len(GIRLS))
