# OpenChat — mise à jour des groupes

Cette version renomme l’application OpenChat et ajoute les conversations de groupe, leurs messages, photos, fichiers et notes vocales, ainsi que les appels audio/vidéo de groupe.

## Supabase

1. Dans le SQL Editor du projet Supabase, vérifie que le schéma initial et `supabase/ui-upgrade.sql` ont déjà été appliqués. Si la version actuelle de `ui-upgrade.sql` n’a pas encore été exécutée, exécute-la d’abord.
2. Exécute ensuite **au complet** `supabase/group-upgrade.sql`. Ce script ajoute les tables et les règles RLS des groupes et de la signalisation des appels. Il ne remplace pas les tables des conversations privées.
3. Attends la réussite du script avant de déployer l’application.

Les appels de groupe utilisent le WebRTC maillé existant, sans serveur TURN : chaque appareil échange le média avec les autres membres. Pour limiter la charge, un appel accepte au maximum cinq participants. Les réseaux qui bloquent les connexions WebRTC directes peuvent quand même empêcher un appel de se connecter; la signalisation Supabase ne relaie pas la vidéo ni l’audio.

## GitHub et Render

1. Décompresse `OpenChat-groups.zip`; tu obtiendras un dossier `OpenChat`.
2. Remplace les fichiers de l’application dans le dépôt GitHub par le contenu du dossier `OpenChat` (y compris le nouveau dossier `supabase/group-upgrade.sql`). Garde les variables et paramètres Render déjà configurés.
3. Enregistre et pousse les changements sur GitHub. Render reconstruira le site depuis le dépôt comme d’habitude.
4. Recharge le site après la fin du déploiement, puis connecte-toi. Le bouton **＋ Groupe** apparaît au-dessus de la liste des contacts. Il faut sélectionner au moins deux contacts acceptés.

Les membres d’un groupe voient les messages, les fichiers, les photos et les notes vocales dans la même conversation. Pour lancer un appel, ouvre le groupe puis touche **Audio** ou **Vidéo**. Les autres membres voient la demande et choisissent **Rejoindre**.

## Limites actuelles

- Le créateur ne peut sélectionner que des contacts acceptés; un groupe contient au maximum 15 personnes.
- Les appels sont maillés, jusqu’à cinq participants, et ne disposent pas de serveur TURN.
- Les appels de groupe ne fonctionnent que pendant que les appareils gardent OpenChat ouvert et connecté.

